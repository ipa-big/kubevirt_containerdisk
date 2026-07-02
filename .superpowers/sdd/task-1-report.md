Task 1 report

Summary:
- Implemented contract and regression harness for Raspberry Pi containerdisk builder.
- Followed TDD: wrote failing test first, observed failure, implemented minimal script, ran tests, fixed re-source issue, re-ran tests.

Files added:
- build-raspios-lite-containerdisk.sh
- tests/build-raspios-lite-containerdisk.test.sh

Commits:
- 1118da6006055d5e82b9c12d96d9d4b666281c3f  test: add fixed Raspberry Pi containerdisk script contract
- 4b4b40a2b91e751235ab4c655e15d376491fe58f  fix: make constants safe to source multiple times

Test run:
- bash tests/build-raspios-lite-containerdisk.test.sh -> PASS

Self-review / Notes:
- The script defines IMG_URL, IMG_NAME, IMG_PLATFORM and default_image_tag().
- To allow sourcing the script multiple times in one shell (tests re-source it), constants are only set when unset.
- main() is intentionally a placeholder returning non-zero; the contract requires source-ability and default_image_tag behavior only for now.
- Commit messages include Co-authored-by trailer per instructions.

No further changes made.
