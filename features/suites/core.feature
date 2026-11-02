Feature: core

  The decisions the server takes from tables a certified LexLean root writes. The theorems are about
  the LexLean definitions. The emitted text and the C that reads it are tested, not proved.

  @SV-01 @build
  Scenario: A response leaves only after its batch commits, and a failure response only after the commit fails
    Given the batch tables in emit/core.lex
    When the Lean kernel checks send_only_after_commit, fail_only_after_failed_commit and committing_follows_commit
    Then no phase and event but committing and a successful commit answer with a send
    And run_list prepares its sends only from the action those tables give

  @SV-02 @build
  Scenario: Only POST writes, every write needs a token, and an unknown method is not found
    Given the route tables in emit/core.lex
    When the Lean kernel checks only_post_writes, every_write_needs_a_token and unknown_methods_are_not_found
    Then every method and path shape reaches a route those theorems cover
    And parse_request takes its route and its token check from those tables

  @SV-03 @build
  Scenario: Reads go on while writes wait, and a held connection keeps its order while the hold queue has room
    Given the hold table in emit/core.lex
    When the Lean kernel checks the five theorems about shouldHold
    Then a read on a connection with nothing held is never held
    And should_hold takes its answer from that table

  @SV-04 @build
  Scenario: The write pause closes at its limit and opens when the log is copied or the wait times out
    Given the gate table in emit/core.lex
    When the Lean kernel checks the four theorems about gateNext
    Then the pause cannot stay closed past a copied log or a timeout
    And the WAL hook and the batch take the pause from that table

  @SV-05 @build
  Scenario: Only an internal failure is a server error
    Given the failure table in emit/core.lex
    When the Lean kernel checks only_an_internal_failure_is_a_server_error
    Then every other failure answers with a client error
    And canned_setup builds every error response from that table

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
