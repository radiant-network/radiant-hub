# Confidentiality

Radiant holds clinical genomic data: patient and sample identifiers, phenotypes, genotypes, variant calls tied to a person. DNA cannot be anonymised, and a few rare variants are enough to identify someone. Anything Claude reads goes to the model provider: treat the context as a third party.

## Propose, never request

Never ask the user for confidential data. Propose a command, query or script that the user runs, and that prints only the signal you need: a count, a distribution, a status code, an error category.

| You may receive | Never ask for |
|---|---|
| Short-lived access tokens, schemas, table and column names, aggregates, status codes, synthetic or local data | Client secrets, passwords, refresh tokens, AWS credentials. Real patient, sample or practitioner identifiers. Raw prod rows or API payloads. Sequencing files (VCF, CRAM, BAM, FASTQ) |

## Environments

State the environment at the start of any task that is not local.

| Env | Data | Tokens | Output |
|---|---|---|---|
| local | synthetic | cache in `tmp/tokens/` | free |
| QA (one for every portal, plus the Ferlease previews) | test data | the user saves them in `tmp/tokens/`, never in the chat: a pasted token stays in the session transcript on disk | free; no dump to disk without need |
| prod (one for every portal) | real patients | never on disk | counts, statuses and IDs only, never a payload; confirm each command before you run it |

Prod covers every access path: the portal API, the MCP server, the databases (directly or through a tunnel), object storage, `kubectl`, `aws`. Run nothing against a real cluster or cloud account without the user's go-ahead.

## Public repos

The hub, `portal`, `etl`, `mcp` and the `bioinfo/*` repos are public. Only the `infra/*` repos are private. Never write an internal hostname or URL, an IP, a cloud account, cluster or bucket name, or any QA or prod setting in a committed file, a commit message, a PR or a PR comment. Keep them out of git: in the `env` of `.claude/settings.local.json`, which git ignores, so that commands use `$VAR` without the value appearing anywhere.

## Warn before you read

Stop and ask before you read a file or fetch a page when:
- its path looks sensitive: patient-like IDs, `prod` in the path, `.vcf[.gz]`, `.cram`, `.bam`, `.fastq[.gz]`, segments like `patient` or `clinical`;
- the user pastes what looks like real names, real IDs or a non-local payload;
- the target is known to hold prod data.

If sensitive data already entered the context, say so in your next message, work from a summary, and recommend `/clear` at the end of the task.

## Secrets

- Never read an env file (`.env`, `.env.*`, any environment) without a go-ahead for that file. A file open in the editor is not a go-ahead. Let the command read the value itself (`$VAR` from the user's shell, `source`).
- Never print a secret: no Read of a token file, no `echo`, no `curl -v`, no `set -x`, no `aws secretsmanager get-secret-value` to stdout. Load it inside the command that uses it, and check only its presence.
- From a token response, only `access_token` and `expires_in` may enter the context.
- Never write a secret, a token or patient data to memory, notes or a committed file.

## After the task

Empty the token files (`> file`, keep the file) and delete the payload dumps in `tmp/`. If a real secret entered the context, tell the user to `/clear` **and** to rotate it at the source: `/clear` does not erase the provider's logs.

When the environment or the data source is unclear, ask before you act.
