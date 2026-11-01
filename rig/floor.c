// The ceiling test: fixed bytes over io_uring, no database, JSON work or JWT. Not a valid entry.
// Whatever this can't reach, no entry on the same kernel and memory can reach either.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <liburing.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <unistd.h>

#define ENTRIES 65536
#define BUFFERS 4096
#define BUFFER_SIZE 2048
#define GROUP 1
enum { OP_ACCEPT, OP_RECV, OP_SEND };

static struct io_uring ring;
static struct io_uring_buf_ring *buffers;
static char *memory;
static char *feed;
static size_t feed_len;
static char small[256];
static size_t small_len;

static struct io_uring_sqe *sqe(void) {
    struct io_uring_sqe *s = io_uring_get_sqe(&ring);
    while (!s) {
        io_uring_submit(&ring);
        s = io_uring_get_sqe(&ring);
    }
    return s;
}

static void arm_recv(int fd) {
    struct io_uring_sqe *s = sqe();
    io_uring_prep_recv_multishot(s, fd, NULL, 0, 0);
    s->flags |= IOSQE_BUFFER_SELECT;
    s->buf_group = GROUP;
    io_uring_sqe_set_data64(s, ((uint64_t)OP_RECV << 32) | (uint32_t)fd);
}

static void arm_accept(int listener) {
    struct io_uring_sqe *s = sqe();
    io_uring_prep_multishot_accept(s, listener, NULL, NULL, 0);
    io_uring_sqe_set_data64(s, ((uint64_t)OP_ACCEPT << 32) | (uint32_t)listener);
}

static void build_feed(void) {
    feed = malloc(16384);
    char *body = malloc(16384);
    size_t n = sprintf(body, "{\"posts\":[");
    for (int i = 1; i <= 20; i++) {
        n += sprintf(body + n, "%s{\"id\":%d,\"body\":\"user%d says hi at 2026-11-01T21:50:40.123Z (VU %d, iter 1)\",\"created_at\":\"2026-11-01T21:50:40.123Z\",\"author\":\"user%d\",\"like_count\":%d}", i > 1 ? "," : "", i, i, i, i, i);
    }
    n += sprintf(body + n, "]}");
    feed_len = sprintf(feed, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", n, body);
    const char *post = "{\"post\":{\"id\":1,\"body\":\"user1 says hi at 2026-11-01T21:50:40.123Z (VU 1, iter 1)\",\"created_at\":\"2026-11-01T21:50:40.123Z\",\"author\":\"user1\",\"like_count\":1}}";
    small_len = sprintf(small, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", strlen(post), post);
    fprintf(stderr, "feed response %zu bytes, post response %zu bytes\n", feed_len, small_len);
}

int main(int argc, char **argv) {
    int port = argc > 1 ? atoi(argv[1]) : 3000;
    struct rlimit nofile = {1048576, 1048576};
    setrlimit(RLIMIT_NOFILE, &nofile);
    build_feed();
    struct io_uring_params params = {.flags = IORING_SETUP_CQSIZE | IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN, .cq_entries = ENTRIES * 8};
    int rc = io_uring_queue_init_params(ENTRIES, &ring, &params);
    if (rc < 0) {
        fprintf(stderr, "io_uring_queue_init: %s\n", strerror(-rc));
        return 1;
    }
    memory = aligned_alloc(4096, BUFFERS * BUFFER_SIZE);
    int bad = 0;
    buffers = io_uring_setup_buf_ring(&ring, BUFFERS, GROUP, 0, &bad);
    if (!buffers) {
        fprintf(stderr, "buffer ring: %s\n", strerror(-bad));
        return 1;
    }
    for (int i = 0; i < BUFFERS; i++) io_uring_buf_ring_add(buffers, memory + i * BUFFER_SIZE, BUFFER_SIZE, i, BUFFERS - 1, i);
    io_uring_buf_ring_advance(buffers, BUFFERS);
    for (int i = 0; i < 8; i++) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
        struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
        if (bind(fd, (struct sockaddr *)&a, sizeof a) || listen(fd, 4096)) {
            perror("listen");
            return 1;
        }
        arm_accept(fd);
    }
    fprintf(stderr, "floor server on %d\n", port);
    for (;;) {
        io_uring_submit_and_wait(&ring, 1);
        struct io_uring_cqe *cqe;
        unsigned head, seen = 0;
        io_uring_for_each_cqe(&ring, head, cqe) {
            seen++;
            uint64_t data = io_uring_cqe_get_data64(cqe);
            int op = data >> 32, fd = (uint32_t)data;
            if (op == OP_ACCEPT) {
                if (cqe->res >= 0) {
                    int one = 1;
                    setsockopt(cqe->res, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
                    arm_recv(cqe->res);
                }
                if (!(cqe->flags & IORING_CQE_F_MORE)) arm_accept(fd);
            } else if (op == OP_RECV) {
                if (cqe->res > 0) {
                    unsigned id = cqe->flags >> IORING_CQE_BUFFER_SHIFT;
                    const char *text = memory + id * BUFFER_SIZE;
                    int is_feed = cqe->res > 9 && memcmp(text, "GET /feed", 9) == 0;
                    struct io_uring_sqe *s = sqe();
                    io_uring_prep_send(s, fd, is_feed ? feed : small, is_feed ? feed_len : small_len, MSG_NOSIGNAL);
                    io_uring_sqe_set_data64(s, ((uint64_t)OP_SEND << 32) | (uint32_t)fd);
                    s->flags |= IOSQE_CQE_SKIP_SUCCESS;
                    io_uring_buf_ring_add(buffers, memory + id * BUFFER_SIZE, BUFFER_SIZE, id, BUFFERS - 1, 0);
                    io_uring_buf_ring_advance(buffers, 1);
                    if (!(cqe->flags & IORING_CQE_F_MORE)) arm_recv(fd);
                } else if (cqe->res == 0 || cqe->res != -ENOBUFS) {
                    close(fd);
                } else {
                    arm_recv(fd);
                }
            }
        }
        io_uring_cq_advance(&ring, seen);
    }
}
