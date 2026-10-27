---
name: request
description: Make authenticated HTTP requests to the Radiant portal API on the local stack (QA once its URLs are listed here), and report status codes and aggregated results. Use to call an endpoint, check a fix against the API, or create test data. Never for prod.
argument-hint: "<endpoint or action> [env] [user]"
---

# Request

The `confidentiality` rule applies to every call. Default environment: local.

## Environments

| Env | Keycloak (realm) | API | Token |
|---|---|---|---|
| local | `http://localhost:8080` (`radiant`) | `http://localhost:8090` | you fetch it (see Token) |
| QA | — | `$RADIANT_QA_API` | the user saves it in the token file |
| prod | — | — | **refused:** no call to prod, whatever the path |

The QA URL never appears in this repo, which is public: the user sets `RADIANT_QA_API` in the `env` of `.claude/settings.local.json` (`confidentiality` rule). If it is unset, ask the user to set it.

The local stack is the portal backend's (`make docker-run`, then `make run`; see `portal/backend/CLAUDE.md`). Demo users: `cbtn-admin`, `cbtn-phi-chop`, `cbtn-phi-sch`, `cbtn-lab`, `cbtn-nophi`, each with its name as password.

## Endpoints

Look an endpoint up in this order and stop at the first hit: `portal/backend/docs/swagger.yaml`, `portal/postman/RADIANT-API.postman_collection.json`, the handlers in `portal/backend`. Never invent one. After you use an endpoint that the Postman collection lacks, offer to add it.

- Most routes take the tenant in the path: `/{tenant}/…` (`radiant` on the local stack).
- Rights come from Radiant's `user_role` table, not from the roles in the JWT. On a `403`, call `GET /auth/me`: it returns the actions that the user holds, per tenant and organisation.
- Batch endpoints are asynchronous: `POST …/batch` answers `202` with a `PENDING` batch. Errors show in the batch status, never as a `400`: poll the batch.

## Token

File: `tmp/tokens/<env>_<user>.json`, the full Keycloak response. Never Read, `cat` or `echo` it: load only `access_token`, inside the command that uses it.

- **Local:** fetch it yourself, for example:
  ```sh
  curl -s -o tmp/tokens/local_cbtn-admin.json -w '%{http_code}\n' http://localhost:8080/realms/radiant/protocol/openid-connect/token -d grant_type=password -d client_id=radiant -d "client_secret=$(jq -r '.clients[] | select(.clientId=="radiant") | .secret' portal/backend/scripts/init-keycloak/radiant.json)" -d username=cbtn-admin -d password=cbtn-admin
  ```
- **QA:** create the empty file and ask the user to save the token response in it. Never ask for a password or a client secret, never fetch the token yourself. On a `401`, ask for a fresh one.
- **Call:** `curl -s -o <file> -w '%{http_code}\n' -H "Authorization: Bearer $(jq -r .access_token tmp/tokens/<env>_<user>.json)" <url>`. Never `curl -v`. On a `401` with a fresh local token, check that its issuer matches the API's `KEYCLOAK_HOST`.

## Test data

MRN prefix `TEST`, never `Cypress` (that reads as end-to-end test data). A real-sounding first name with an invented last name, never a real identity. One MRN per patient: Radiant dedups patients on `(organization, mrn)`.

## Saving

Save a payload and its response only when the call changes data, the payload was costly to build, or the response gets read again: `tmp/requests/<ticket|adhoc>/<purpose>/<request>/{payload.json,response.json}`. Never for a read-only check. When you report, list the paths that you created and propose to delete them.
