# A failed enable save leaves the new flag

Alert Toggle and the Manager enable checkbox, including a Group row, set an Entry's enabled flag and then save that Scope's Bucket. The runtime effect comes first. If the save fails, the new flag stays for this session. The next load reads the Bucket.

## Considered options

Roll the flag back when the save fails, so the row and the Bucket always agree. Rejected. Alert Toggle exists for the runtime effect. The checkbox follows that rule.

## Consequences

This is the same flag. There is no session-only enable. A failed encode and a rejected PersistentDB write are each a log line. Neither opens a dialog. The Entry is ahead of the Bucket until a save of that Bucket succeeds. A later successful save of that Bucket, including an Editor autosave, writes the new flag with the rest of the document. The next load brings the old flag back only when no save of that Bucket succeeds after the failure. Each matched Alert is its own save. Disable still releases visuals when the flag changes to off, including when the save fails. Enable still does not restore them. Group disable still does not write child flags.
