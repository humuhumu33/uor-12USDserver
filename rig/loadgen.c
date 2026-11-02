// Native replay of bench/load.js: one keep-alive connection per user, the same think times and mix.
// k6 can't hold enough users on one runner. Not part of any submission.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

enum { ST_CONNECT, ST_FEED, ST_POST, ST_DECIDE, ST_LIKE, ST_CREATE };
#define SLOT_MS 10
#define SLOTS 4096
#define NONE UINT32_MAX
#define HIST 1400

typedef struct {
    int fd;
    uint32_t next;
    uint32_t post;
    uint32_t remaining;
    uint64_t sent_at;
    uint8_t step;
    uint8_t waiting;
    uint8_t on_wheel;
} User;

static User *users;
static uint32_t wheel[SLOTS];
static uint64_t wheel_at;
static uint64_t seed = 88172645463325252ULL;
static uint64_t hold_hist[HIST], window_hist[HIST];
static uint64_t hold_requests, hold_errors, window_requests, window_errors, refused;
static double worst_window_p99;
static int epfd;
static struct sockaddr_in server;
static char **tokens;
static uint32_t token_count;
static int in_hold;
static uint32_t open_connections;
static char reads[262144];

static uint64_t now_us(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000 + t.tv_nsec / 1000;
}

static double uniform(double lo, double hi) {
    seed ^= seed << 13;
    seed ^= seed >> 7;
    seed ^= seed << 17;
    return lo + (seed >> 11) * (1.0 / 9007199254740992.0) * (hi - lo);
}

static void schedule(uint32_t id, double seconds) {
    // A dropped connection can reach a user who is already thinking; twice on the wheel makes a cycle.
    if (users[id].on_wheel) return;
    users[id].on_wheel = 1;
    uint64_t slots = (uint64_t)(seconds * 1000 / SLOT_MS) + 1;
    uint32_t slot = (wheel_at + slots) % SLOTS;
    users[id].next = wheel[slot];
    wheel[slot] = id;
}

static int bucket(uint64_t us) {
    int b = (int)(log2((double)us + 1) * 32);
    return b >= HIST ? HIST - 1 : b;
}

static double bucket_ms(int b) { return (pow(2.0, b / 32.0) - 1) / 1000.0; }

static double percentile(const uint64_t *h, double p) {
    uint64_t total = 0, seen = 0;
    for (int i = 0; i < HIST; i++) total += h[i];
    if (!total) return 0;
    for (int i = 0; i < HIST; i++) {
        seen += h[i];
        if ((double)seen >= p * total) return bucket_ms(i);
    }
    return 0;
}

static void record(uint64_t us, int ok) {
    int b = bucket(us);
    window_hist[b]++;
    window_requests++;
    if (!ok) window_errors++;
    if (in_hold) {
        hold_hist[b]++;
        hold_requests++;
        if (!ok) hold_errors++;
    }
}

static void open_user(uint32_t id);

static void drop_user(uint32_t id, int count_error) {
    User *u = &users[id];
    if (u->fd >= 0) {
        close(u->fd);
        u->fd = -1;
        open_connections--;
    }
    if (count_error) record(u->sent_at ? now_us() - u->sent_at : 1, 0);
    u->sent_at = 0;
    u->waiting = 0;
    u->step = ST_FEED;
    schedule(id, uniform(1, 3));
}

static void send_request(uint32_t id) {
    User *u = &users[id];
    char text[1024];
    int n = 0;
    const char *common = "Host: bench\r\nUser-Agent: k6/1.0 (https://k6.io/)\r\n";
    const char *token = tokens[id % token_count];
    switch (u->step) {
    case ST_FEED:
        n = snprintf(text, sizeof text, "GET /feed HTTP/1.1\r\n%s\r\n", common);
        break;
    case ST_POST:
        n = snprintf(text, sizeof text, "GET /posts/%u HTTP/1.1\r\n%s\r\n", u->post, common);
        break;
    case ST_LIKE:
        n = snprintf(text, sizeof text, "POST /posts/%u/like HTTP/1.1\r\n%sAuthorization: Bearer %s\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n", u->post, common, token);
        break;
    default: {
        char body[128];
        int b = snprintf(body, sizeof body, "{\"body\":\"user says hi at 2026-11-01T21:50:40.123Z (VU %u, iter 1)\"}", id);
        n = snprintf(text, sizeof text, "POST /posts HTTP/1.1\r\n%sAuthorization: Bearer %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s", common, token, b, body);
    }
    }
    u->sent_at = now_us();
    u->remaining = 0;
    u->waiting = 1;
    if (send(u->fd, text, n, MSG_NOSIGNAL) != n) drop_user(id, 1);
}

static void after_response(uint32_t id, int ok) {
    User *u = &users[id];
    record(now_us() - u->sent_at, ok);
    u->sent_at = 0;
    u->waiting = 0;
    switch (u->step) {
    case ST_FEED:
        if (ok) u->step = ST_POST;
        schedule(id, uniform(3, 7));
        break;
    case ST_POST:
        u->step = ST_DECIDE;
        schedule(id, uniform(3, 8));
        break;
    case ST_LIKE:
        if (uniform(0, 1) < 0.02) {
            u->step = ST_CREATE;
            send_request(id);
        } else {
            u->step = ST_FEED;
            schedule(id, uniform(5, 15));
        }
        break;
    default:
        u->step = ST_FEED;
        schedule(id, uniform(5, 15));
    }
}

static void on_readable(uint32_t id) {
    User *u = &users[id];
    for (;;) {
        ssize_t got = recv(u->fd, reads, sizeof reads, MSG_DONTWAIT);
        if (got == 0) {
            drop_user(id, u->waiting);
            return;
        }
        if (got < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;
            drop_user(id, u->waiting);
            return;
        }
        if (!u->waiting) continue;
        if (u->remaining == 0) {
            char *end = memmem(reads, got, "\r\n\r\n", 4);
            if (!end) {
                drop_user(id, 1);
                return;
            }
            int status = got > 12 ? atoi(reads + 9) : 0;
            uint32_t declared = 0;
            for (char *p = reads; p && p < end; p = memchr(p, '\n', end - p), p = p ? p + 1 : p) {
                if (strncasecmp(p, "content-length:", 15) == 0) {
                    declared = strtoul(p + 15, NULL, 10);
                    break;
                }
            }
            char *body = end + 4;
            uint32_t have = got - (body - reads);
            int ok = status == 200 || status == 201;
            if (u->step == ST_FEED && ok) {
                // Pick one id from what arrived, as load.js picks one post from the feed.
                uint32_t found = 0, chosen = 1;
                char *p = body;
                char *limit = reads + got;
                while ((p = memmem(p, limit - p, "\"id\":", 5))) {
                    p += 5;
                    found++;
                    if (uniform(0, found) < 1) chosen = strtoul(p, NULL, 10);
                }
                u->post = chosen ? chosen : 1;
            }
            if (have >= declared) {
                after_response(id, ok);
                continue;
            }
            u->remaining = declared - have;
            continue;
        }
        if ((uint32_t)got >= u->remaining) {
            u->remaining = 0;
            after_response(id, 1);
        } else {
            u->remaining -= got;
        }
    }
}

static void open_user(uint32_t id) {
    User *u = &users[id];
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    if (fd < 0) {
        perror("socket");
        schedule(id, 1);
        return;
    }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    setsockopt(fd, IPPROTO_IP, IP_BIND_ADDRESS_NO_PORT, &one, sizeof one);
    struct sockaddr_in source = {.sin_family = AF_INET};
    source.sin_addr.s_addr = htonl(0x7F010001 + id % 32);
    bind(fd, (struct sockaddr *)&source, sizeof source);
    u->fd = fd;
    open_connections++;
    u->step = u->step ? u->step : ST_FEED;
    struct epoll_event e = {.events = EPOLLIN | EPOLLOUT, .data.u32 = id};
    epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &e);
    u->sent_at = now_us();
    u->waiting = 2;
    if (connect(fd, (struct sockaddr *)&server, sizeof server) < 0 && errno != EINPROGRESS) {
        refused++;
        drop_user(id, 1);
    }
}

static void on_due(uint32_t id) {
    User *u = &users[id];
    if (u->fd < 0) {
        open_user(id);
        return;
    }
    if (u->step == ST_DECIDE) {
        if (uniform(0, 1) < 0.15) {
            u->step = ST_LIKE;
        } else if (uniform(0, 1) < 0.02) {
            u->step = ST_CREATE;
        } else {
            u->step = ST_FEED;
            schedule(id, uniform(5, 15));
            return;
        }
    }
    send_request(id);
}

int main(int argc, char **argv) {
    if (argc < 6) {
        fprintf(stderr, "usage: loadgen port users ramp_s hold_s tokens_file\n");
        return 2;
    }
    int port = atoi(argv[1]);
    uint32_t count = strtoul(argv[2], NULL, 10);
    double ramp = atof(argv[3]), hold = atof(argv[4]);
    FILE *tf = fopen(argv[5], "r");
    if (!tf) {
        perror("tokens");
        return 2;
    }
    tokens = calloc(20000, sizeof *tokens);
    char line[1024];
    while (token_count < 20000 && fgets(line, sizeof line, tf)) {
        line[strcspn(line, "\r\n")] = 0;
        tokens[token_count++] = strdup(line);
    }
    struct rlimit nofile = {1048576, 1048576};
    setrlimit(RLIMIT_NOFILE, &nofile);
    server.sin_family = AF_INET;
    server.sin_port = htons(port);
    server.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    users = calloc(count, sizeof *users);
    for (uint32_t i = 0; i < count; i++) users[i].fd = -1;
    for (int i = 0; i < SLOTS; i++) wheel[i] = NONE;
    epfd = epoll_create1(0);
    static struct epoll_event events[8192];
    uint64_t start = now_us();
    uint64_t last_slot = 0, started = 0, next_window = start + 10000000, hold_start = 0;
    uint64_t end = start + (uint64_t)((ramp + hold) * 1000000);
    for (;;) {
        uint64_t now = now_us();
        if (now >= end) break;
        if (!in_hold && now >= start + (uint64_t)(ramp * 1000000)) {
            in_hold = 1;
            hold_start = now;
            printf("HOLD start connections=%u\n", open_connections);
            fflush(stdout);
        }
        uint64_t due = ramp > 0 ? (uint64_t)((now - start) / (ramp * 1000000) * count) : count;
        if (due > count) due = count;
        while (started < due) {
            uint32_t id = started++;
            users[id].step = ST_FEED;
            schedule(id, uniform(0, 5));
        }
        uint64_t slot = (now - start) / (SLOT_MS * 1000);
        while (last_slot < slot) {
            last_slot++;
            wheel_at = last_slot;
            uint32_t s = last_slot % SLOTS;
            uint32_t id = wheel[s];
            wheel[s] = NONE;
            while (id != NONE) {
                uint32_t following = users[id].next;
                users[id].on_wheel = 0;
                on_due(id);
                id = following;
            }
        }
        int n = epoll_wait(epfd, events, 8192, 2);
        for (int i = 0; i < n; i++) {
            uint32_t id = events[i].data.u32;
            User *u = &users[id];
            if (u->fd < 0) continue;
            if (u->waiting == 2) {
                int err = 0;
                socklen_t len = sizeof err;
                getsockopt(u->fd, SOL_SOCKET, SO_ERROR, &err, &len);
                if (err) {
                    refused++;
                    u->waiting = 0;
                    u->sent_at = now_us();
                    drop_user(id, 1);
                    continue;
                }
                struct epoll_event e = {.events = EPOLLIN, .data.u32 = id};
                epoll_ctl(epfd, EPOLL_CTL_MOD, u->fd, &e);
                u->waiting = 0;
                send_request(id);
                continue;
            }
            if (events[i].events & (EPOLLIN | EPOLLHUP | EPOLLERR)) on_readable(id);
        }
        if (now >= next_window) {
            double p99 = percentile(window_hist, 0.99);
            printf("WINDOW t=%.0f connections=%u requests=%lu errors=%lu refused=%lu p50=%.1f p99=%.1f\n", (now - start) / 1e6, open_connections, window_requests, window_errors, refused, percentile(window_hist, 0.5), p99);
            fflush(stdout);
            if (in_hold && p99 > worst_window_p99) worst_window_p99 = p99;
            memset(window_hist, 0, sizeof window_hist);
            window_requests = window_errors = 0;
            next_window += 10000000;
        }
    }
    double seconds = (now_us() - hold_start) / 1e6;
    printf("LOAD users=%u hold_s=%.0f connections=%u requests=%lu rps=%.0f errors=%lu error_pct=%.3f refused=%lu p50=%.2f p95=%.2f p99=%.2f p999=%.2f worst10s_p99=%.2f\n",
           count, seconds, open_connections, hold_requests, hold_requests / seconds, hold_errors, hold_requests ? 100.0 * hold_errors / hold_requests : 0, refused,
           percentile(hold_hist, 0.5), percentile(hold_hist, 0.95), percentile(hold_hist, 0.99), percentile(hold_hist, 0.999), worst_window_p99);
    return 0;
}
