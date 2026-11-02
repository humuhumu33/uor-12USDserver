Feature: core

  The decisions the server takes from tables a certified LexLean root writes. The theorems are about
  the LexLean definitions. The emitted text and the C that reads it are tested, not proved.

  @SV-01 @build
  Scenario: A batch's responses leave only after its commit, and they are replaced by failures only when the commit fails
    Given the batch tables in emit/core.lex
    When the Lean kernel checks send_only_after_commit, fail_only_after_failed_commit and committing_follows_commit
    Then no phase and event but committing and a successful commit answer with a send to the whole batch
    And run_list prepares its sends only from the action those tables give

  @SV-02 @build
  Scenario: Only POST writes, every write needs a token, and an unknown method is not found
    Given the route tables in emit/core.lex
    When the Lean kernel checks only_post_writes, every_write_needs_a_token and unknown_methods_are_not_found
    Then every method and path shape reaches a route those theorems cover
    And parse_request takes its route and its token check from those tables

  @SV-03 @build
  Scenario: While the hold queue has room, the hold table holds no read on a connection with nothing held, every write at a closed gate, and every later request on a held connection
    Given the hold table in emit/core.lex
    When the Lean kernel checks the five theorems about shouldHold
    Then the table holds no read on a connection with nothing held
    And should_hold takes its answer from that table

  @SV-04 @build
  Scenario: The write pause closes at its limit and opens when the log is copied or the wait times out
    Given the gate table in emit/core.lex
    When the Lean kernel checks the four theorems about gateNext
    Then the pause cannot stay closed past a copied log or a timeout
    And the WAL hook and the batch take the pause from that table

  @SV-05 @build
  Scenario: In the failure table, only an internal failure is a server error
    Given the failure table in emit/core.lex
    When the Lean kernel checks only_an_internal_failure_is_a_server_error
    Then every other failure in the table answers with a client error
    And canned_setup builds the table's responses from it, while the 503 from health is written by hand

  @SV-06 @build
  Scenario: A quote, a backslash and the control bytes are escaped at the checked values, and the emitted table matches the rule for all 256 bytes
    Given the byte class definition in emit/core.lex
    When the Lean kernel checks the six theorems about escapeClass
    And core_test compares the emitted table and the word test with the rule for every byte in every lane
    Then the theorems hold at bytes 0, 31, 32, 34, 92 and 255
    And put_escaped takes its class from that table

  @SV-07 @build
  Scenario: Every file in server is what the certified root writes, and the committed module is not stale
    Given the committed module in emit/project/src/Emit.lex.tex
    When just vv runs emit/sdk-emit.sh
    Then regenerating the module gives the committed bytes
    And the root writes every file in server byte for byte

  @SV-08 @build
  Scenario: The box's build checks the theorems and every file with official Lean alone, and stops on a false, weakened or deleted theorem, a sorry, an added axiom or an edited file
    Given the folder emit/submission/sdk-export.sh writes
    When build.sh runs with official Lean and nothing from the SDK
    Then lake build rejects a false or weakened theorem, a deleted theorem, an added axiom and, with warnings as failures, a sorry
    And any file here that differs from what the program writes stops the build, the C included
