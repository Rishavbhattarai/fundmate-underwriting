# FundMate Underwriting Integration

A native Salesforce app that builds Funding Applications from Account, Contact and bank statement data, sends them to an external Underwriting API in batches of 50, receives signed decisions through an Apex REST endpoint, creates Funding Offers, and routes each decided application to a specialist queue.

Thresholds, the request field mapping and the routing rules live in Custom Metadata, so an admin can change them in Setup without a deployment.

**Install:** [unlocked package, version 1.0.0](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tbm000000vSafAAE) (`04tbm000000vSafAAE`), or deploy from source as described in [Setup](#setup).

- [Architecture](#architecture)
- [Setup](#setup)
- [Testing](#testing)
- [Results from a live org](#results-from-a-live-org)
- [API reference](#api-reference)
- [Validation](#validation)
- [Error handling](#error-handling)
- [Scale and governor limits](#scale-and-governor-limits)
- [Security](#security)
- [Configuration](#configuration)
- [Questions and assumptions](#questions-and-assumptions)
- [Project layout](#project-layout)
- [CI and packaging](#ci-and-packaging)

---

## Architecture

```
Creating applications
  Account (business) + Contact (owners) + Bank_Statement__c (monthly, on the Account)
    -> "New Funding Application" Flow on the Account
    -> FinancialSnapshotService copies the latest statements onto the application

Sending applications
  Funding_Application__c set to Ready            ("Send to Underwriting" button; the trigger re-snapshots and validates)
    -> UnderwritingDispatcher                    (15-minute schedule, the button, or a retry)
    -> UnderwritingClaimService                  (FOR UPDATE: Ready -> Queued, stamps a batch key)
    -> UnderwritingSendBatch, scope 50           (one callout per execute, through the Named Credential)
    -> UnderwritingBatchSender                   (one Idempotency-Key per batch, stored on each application)
    -> Status, Status Reason and Tracking Id saved per application
    -> transient failure: UnderwritingRetryJob resends the same batch with the same key
    -> Rejected or Send Failed: routed to Integration Exceptions; owner and admins alerted

Receiving decisions
  Underwriting API -> POST /services/apexrest/underwriting/decisions
    -> OAuth client credentials, running as the integration user (any other user gets 403)
    -> HMAC-SHA256 signature check on the raw body
    -> DecisionProcessor validates each decision, skips duplicates, saves decisions and offers
    -> Funding_Application__c status = decision
    -> Route_Decided_Funding_Application Flow assigns a queue from Routing_Rule__mdt
```

Errors are published to `Integration_Log_Event__e` (Publish Immediately) and stored in `Integration_Log__c`, so a log is kept even when its transaction rolls back.

### Data model

| Object | Purpose | Key fields |
|---|---|---|
| Account | The business | Name (legal name), `EIN__c` (encrypted), BillingState, `Business_Start_Date__c`, `Time_in_Business_Months__c` |
| Contact | An owner | FirstName, LastName, `Date_of_Birth__c` (encrypted, YYYY-MM-DD), `SSN__c` (encrypted), `Ownership_Percentage__c` |
| `Funding_Application__c` | The request (private sharing). Name is the `applicationReference` (FA-000123) | Requested Amount, Use of Funds, Status, Status Reason, Tracking Id, Batch Key, Idempotency Key, Retry Count, Next Retry At; snapshot of the latest statements; Average Monthly Deposits; Below Revenue Minimum |
| `Bank_Statement__c` | One month of bank activity (master-detail to Account) | Statement Month (normalised to the 1st), Total Deposits, NSF Count, Month Key (unique per business and month) |
| `Underwriting_Decision__c` | One received decision | `Decision_Id__c` (unique), Decision, Decision Reason, Tracking Id |
| `Funding_Offer__c` | An offer | `Offer_Id__c` (unique), Funding Amount, Factor Rate, Term, Payment Frequency, Superseded; calculated Total Payback, Cost of Financing, Number of Payments, Payment Amount, Estimated APR |
| `Integration_Log__c` | Errors and limit snapshots | Level, Source, Message, Details, Record Id, Batch Key, HTTP Status, Limits Snapshot |

Statements belong to the business, so they exist before any application. The application snapshots the latest statements when it is created and again when it is submitted. Underwriting sees exactly what was sent, and later statements don't change a submitted application.

Status flow: `Draft` → `Ready` (or `Validation Failed`) → `Queued` → `Acknowledged` / `Rejected` / `Send Failed` → `Approved` / `Declined` / `Needs More Info`.

### Business rules

Several rules come from FundMate's public site and from the state laws that apply to the sample businesses:

- FundMate underwrites on bank cash flow and asks for an average of $10,000 a month over the last 3 months. Applications need three consecutive recent statements. Averages below the minimum are flagged (`Below_Revenue_Minimum__c`) but still sent.
- Terms run 3 to 18 months with daily, weekly or monthly payments. Offers outside that range are rejected.
- The sample businesses are in NY, TX, FL and CA, which all have commercial financing disclosure laws. Each offer stores total payback, cost of financing, payment amount and an estimated APR, and the Offer Comparison component shows them side by side. The APR is an estimate for comparison, not a legal disclosure.

---

## Setup

Requirements: Salesforce CLI (`sf`), Node 20+, and a Developer Edition org or a Dev Hub.

### 1. Deploy

```bash
# Scratch org
sf org create scratch --definition-file config/project-scratch-def.json --alias fundmate --duration-days 30 --set-default
sf project deploy start --target-org fundmate

# Or an existing org
sf project deploy start --target-org <alias> --source-dir force-app
```

The deploy includes the five queues and the Integration Admins group. Installing the package instead gives the same result.

### 2. Assign permission sets

| Permission set | For |
|---|---|
| `FundMate_Admin` | Admins. Full access, including **View Encrypted Data** for SSN, EIN and date of birth |
| `FundMate_Funding_Specialist` | Specialists. Works applications and offers; SSN, EIN and date of birth are masked; Status is read-only |
| `FundMate_Integration` | The Underwriting API integration user. API only |

```bash
sf org assign permset --name FundMate_Admin --target-org fundmate
```

Add specialists to the queues they work: Funding Specialists, Senior Funding Specialists, Document Collection, Declined Review and Integration Exceptions.

### 3. Secrets

Secrets are never stored in source. Generate local test values in `.env.local` (gitignored):

```bash
printf "SIGNING_SECRET=%s\nMOCK_API_KEY=%s\n" "$(openssl rand -hex 32)" "$(openssl rand -hex 24)" > .env.local
```

The **signing secret**, used to verify inbound requests, goes in a protected custom setting:

```bash
sf apex run --target-org fundmate <<EOF
Underwriting_Secret__c s = Underwriting_Secret__c.getOrgDefaults();
s.Signing_Secret__c = '$(grep SIGNING_SECRET .env.local | cut -d= -f2)';
upsert s;
EOF
```

The **API key**, used for outbound calls, goes on the External Credential: Setup → Named Credentials → External Credentials → *Underwriting API Credential* → Principals → *UnderwritingPrincipal* → add an Authentication Parameter named `ApiKey` with the `MOCK_API_KEY` value.

### 4. Mock Underwriting API

The mock is a Cloudflare Worker in `mock-api/`:

```bash
cd mock-api
npx wrangler login
npx wrangler deploy
grep MOCK_API_KEY ../.env.local | cut -d= -f2 | tr -d '\n' | npx wrangler secret put API_KEY
```

Set the deployed URL on the Named Credential (Setup → Named Credentials → *Underwriting API*). Apex only references `callout:Underwriting_API`.

The mock returns `Acknowledged` or `Rejected` per application and simulates failures based on the business name, so each case is repeatable:

| Business name contains | Mock returns |
|---|---|
| `RATE LIMIT` | 429 with `Retry-After: 60` |
| `SERVER ERROR` | 503 with `Retry-After: 30` |
| `TIMEOUT` | Waits 25 s, past the 20 s callout timeout |
| `BAD REQUEST` | 400 |

Applications without a complete owner are rejected with "Identity not verified.", and averages under $10,000 are rejected as below the minimum.

### 5. Schedules and queue membership

```bash
sf apex run --target-org fundmate --file scripts/apex/setup-org.apex
```

This schedules the 15-minute send run and the nightly log purge, and adds the running user to the five queues and Integration Admins. It is safe to run more than once.

### 6. Integration user and partner OAuth app

```bash
scripts/create-partner-app.sh fundmate
```

This creates:
- the API-only integration user (Salesforce Integration license, **Minimum Access - API Only Integrations** profile, `FundMate_Integration` permission set)
- the **FundMate Underwriting Partner** connected app, using the client-credentials flow and running as that user

The client id and secret are generated into `.env.local`. Only a template (`org-config/`) is in the repository.

The Underwriting API gets a token from `POST /services/oauth2/token` (`grant_type=client_credentials`) and calls the endpoint with `Authorization: Bearer <token>`. The endpoint requires the `FundMate_Post_Underwriting_Decisions` custom permission, which only `FundMate_Integration` grants. A valid token for any other user, including an admin, gets **403**.

### Using the app

1. Open the **FundMate** app, then a business (Account). The business page shows the underwriting fields (EIN, State, Business Start Date, editable in place with validation), the owners, the bank statements, the applications and a **New Funding Application** form. Owner pages show SSN, Date of Birth and Ownership %. Both pages are assigned only in the FundMate app, so existing layouts are unchanged.
2. Open the application and press **Send to Underwriting**. Anything missing is listed on screen; otherwise the application is queued and sent within minutes.
3. Decisions arrive through the API, create offers (compared in **Offer Comparison**), and move the application to a queue.

---

## Testing

### Apex tests

```bash
sf apex run test --target-org fundmate --class-names FundingApplicationValidatorTest,UnderwritingSendTest,UnderwritingDecisionResourceTest,SupportingServicesTest,ValidationRulesTest,SpecialistAccessTest --code-coverage --result-format human --wait 30
```

58 tests, 95% coverage, every class above 85%. The tests cover:
- the pre-send validator, including readable messages
- claim exclusivity, and a claim of 1,000 applications
- retries with Retry-After and backoff, the same Idempotency-Key on every retry of a batch, and a new key on resend
- routing of rejections and send failures to Integration Exceptions
- 200 decisions in one request, with limit assertions
- signature checks, and 403 for any user other than the integration user
- duplicates and superseded offers
- a log that is kept after a rollback
- failure alerts
- all 33 validation rules
- log masking of dates of birth and bank data, and the retention purge
- the security model, run as a Funding Specialist user: private applications, read-only Status, sending their own application

User-mode code is tested as a user holding the FundMate permission sets, not as a system administrator. The same suite passes in CI and in Salesforce's package build org.

### Sample data

```bash
sf apex run --target-org fundmate --file scripts/apex/seed-sample-data.apex     # the brief's four businesses plus Small Shop Bakery (Draft)
sf apex run --target-org fundmate --file scripts/apex/seed-failure-demo.apex    # two applications that trigger 429 and 503
for i in 1 2 3 4; do sf apex run --target-org fundmate --file scripts/apex/seed-scale.apex; done   # 1,000 Ready applications
sf apex run --target-org fundmate --file scripts/apex/reset-demo-data.apex      # remove sample data
```

Expected results:
- **Blue Harbor Coffee and Ridgeview Auto** pass validation and are acknowledged.
- **Lumen Dental** fails: it has only two statements.
- **Cedar and Pine** fails on the missing EIN and the "Calif." state. Fix both on its business page and resend.
- **Small Shop Bakery** passes validation (flagged below the revenue minimum), and the partner rejects it, so it lands in Integration Exceptions.

### Sending decisions

`scripts/send-decisions.mjs` plays the Underwriting API. It gets a client-credentials token as the integration user (`PARTNER_CLIENT_ID` and `PARTNER_CLIENT_SECRET` in `.env.local`), signs the body with `SIGNING_SECRET`, and posts to the org.

```bash
node scripts/send-decisions.mjs data/decisions/sample-decision.json --org fundmate              # one decision
node scripts/send-decisions.mjs --generate 200 --org fundmate                                   # 200 decisions for Acknowledged applications
node scripts/send-decisions.mjs data/decisions/sample-decision.json --org fundmate --tamper     # 401
node scripts/send-decisions.mjs data/decisions/sample-decision.json --org fundmate --stale      # 401
node scripts/send-decisions.mjs data/decisions/invalid-decisions.json --org fundmate            # each decision rejected with a reason
node scripts/send-decisions.mjs data/decisions/sample-decision.json --org fundmate --as-cli     # your own admin token: 403
```

### Calling the endpoint with curl

Get a token for the integration user:

```bash
curl -s -X POST "https://<my-domain>.my.salesforce.com/services/oauth2/token" \
  -d grant_type=client_credentials -d client_id="$CLIENT_ID" -d client_secret="$CLIENT_SECRET"
```

Sign and send a payload:

```bash
BODY="$(cat data/decisions/sample-decision.json | tr -d '\n')"
TS="$(date +%s)"
SIG="$(printf '%s.%s' "$TS" "$BODY" | openssl dgst -sha256 -hmac "$SIGNING_SECRET" | awk '{print $2}')"
curl -s -X POST "$INSTANCE_URL/services/apexrest/underwriting/decisions" \
  -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
  -H "X-Timestamp: $TS" -H "X-Signature: $SIG" --data "$BODY"
```

The response is `200` with a result per decision. The sample file uses the brief's `FA-000123`, so as written it returns `rejected: Unknown applicationReference FA-000123`. Set `applicationReference` and `trackingId` to an Acknowledged application's values to get `created`. Change one character of `$SIG`, or set `TS` to an hour ago, and the response is `401`.

---

## Results from a live org

Run in a Developer Edition org on November 4, 2026, against the deployed mock API.

| Check | Result |
|---|---|
| 1,000 Ready applications, two send runs started at the same moment | 1 batch job, 20 of 20 executes, 0 errors. All 1,000 carried one batch key, so none was claimed twice, and the mock acknowledged all 1,000 |
| Limits per execute | Claim of 1,000: 2 SOQL, 1 DML, 390 ms CPU. Each batch of 50: 4 SOQL, 1 DML, about 110 ms CPU, 1 callout |
| 200 signed decisions in one request | All 200 created in 5.7 s: 6 SOQL, 4 DML statements, 367 ms CPU |
| 429 with `Retry-After: 60` | 5 attempts about 60 seconds apart, all with the same Idempotency-Key, then Send Failed and routed to Integration Exceptions |
| End to end | A new application went Ready → Queued → Acknowledged → Approved, with both offers saved and routing to Funding Specialists |
| Endpoint security | Tampered, stale and unsigned requests: 401. Admin token: 403. Replayed request: no duplicate written. 24-month offer: rejected with a reason |
| Sample data | Blue Harbor, Ridgeview and Cedar and Pine (after its data was fixed on screen) acknowledged; Small Shop Bakery rejected and routed to Integration Exceptions |
| Missing API key | Send Failed immediately with the reason, alert sent, no retry loop |
| Browser test as a user | Empty form, $0 amount, EIN without the dash, SSN without dashes and an under-18 owner each blocked with a clear message |

---

## API reference

### Outbound: `POST {Named Credential}/v1/applications/batch`

Headers:
- `X-Api-Key`, added by the Named Credential
- `Idempotency-Key`, a UUID generated once per batch, stored on each application and reused on every retry of that batch (cleared when a user resends)
- `Content-Type: application/json`

```json
{
  "applications": [
    {
      "applicationReference": "FA-000123",
      "business": { "legalName": "Blue Harbor Coffee LLC", "ein": "12-3456789", "state": "NY", "timeInBusinessMonths": 72 },
      "owners": [
        { "firstName": "Maria", "lastName": "Lopez", "dateOfBirth": "1984-03-14", "ssn": "123-45-6789", "ownershipPercentage": 100 }
      ],
      "financials": { "averageMonthlyDeposits": 53250.00, "totalNsfCount": 0, "numberOfStatements": 3 },
      "fundingRequest": { "requestedAmount": 75000.00, "useOfFunds": "Working Capital" }
    }
  ]
}
```

Keys and source fields come from `Payload_Field_Map__mdt`; adding a record adds a key.

Response:

```json
{
  "batchId": "b-20261030-0001",
  "results": [
    { "applicationReference": "FA-000123", "status": "Acknowledged", "statusReason": "Queued for review.", "trackingId": "UW-88412" },
    { "applicationReference": "FA-000124", "status": "Rejected", "statusReason": "Identity not verified." }
  ]
}
```

### Inbound: `POST /services/apexrest/underwriting/decisions`

Headers:
- `Authorization: Bearer <OAuth token>`
- `X-Timestamp: <unix seconds>`
- `X-Signature: hex(HMAC-SHA256(secret, timestamp + "." + rawBody))`

Request: see `data/decisions/sample-decision.json`. Up to 500 decisions per request (configurable).

```json
{
  "received": 3, "created": 1, "duplicate": 1, "rejected": 1,
  "results": [
    { "decisionId": "DEC-55102", "applicationReference": "FA-000123", "result": "created" },
    { "decisionId": "DEC-55102", "applicationReference": "FA-000123", "result": "duplicate", "reason": "decisionId DEC-55102 was already processed." },
    { "decisionId": "DEC-55103", "applicationReference": "FA-999999", "result": "rejected", "reason": "Unknown applicationReference FA-999999." }
  ]
}
```

| Status | When |
|---|---|
| 200 | Processed. Each result is `created`, `duplicate` or `rejected` with a reason |
| 400 | Body isn't JSON or has no `decisions` array |
| 401 | Signature missing or invalid, or timestamp older than 5 minutes |
| 403 | Caller isn't the integration user |
| 413 | More decisions than `Max_Decisions_Per_Request__c` |
| 500 | Unexpected error. Nothing was applied, so the request is safe to retry |

Each decision must have:
- `decisionId`, `trackingId` and `applicationReference`
- a valid decision value
- a known application in an accepting status (Acknowledged or Needs More Info)
- a `trackingId` matching the one returned when the application was acknowledged
- at least one offer if Approved, and none otherwise
- offers with a positive amount, a factor rate from 1 to 5, a whole-number term from 3 to 18 months, a Daily, Weekly or Monthly frequency, and a unique offer id

---

## Validation

Bad data is stopped at three layers:

| Layer | Examples |
|---|---|
| Validation rules on records (16) | EIN, SSN and date-of-birth formats; owners 18 or older; ownership 0 to 100%; amount above zero; no negative deposits or future months; business, amount and use of funds locked while with underwriting; offer ranges matching the endpoint's |
| Validation rules on Custom Metadata (17) | Batch size 1 to 50, retry and timeout ranges, signature window, log retention 7 to 3,650 days, term range, routing min ≤ max, JSON key format, a message for every regex. An admin can't save a broken configuration |
| Flows and Apex | One statement per business per month (Bank Statement Defaults flow and a unique key); the New Funding Application screen checks the amount and use of funds; Send to Underwriting runs the full pre-send check and lists every reason; the endpoint validates each decision |

## Error handling

| Case | Handling |
|---|---|
| Missing or badly formatted fields | Blocked before sending. Status `Validation Failed`, with every reason in Status Reason |
| Broken field mapping in Custom Metadata | Reported as a configuration error on the application; nothing is sent |
| 429 or 5xx | Retried as the same batch with the same Idempotency-Key: a delayed Queueable for waits up to 10 minutes, a one-off scheduled job for longer waits. `Retry-After` is honoured; otherwise exponential backoff with full jitter. After `Max_Attempts__c`: Send Failed, routed to Integration Exceptions, alert sent |
| Timeout | Retried the same way, with the same key (the partner ignores a repeated key for 24 hours) |
| 400, 401, 403 | Not retried. Send Failed with the API's message, alert sent |
| Application missing from a response | Retried for that application only, with a new key |
| Bad decision in a request | That decision is rejected with a reason; the rest are saved |
| Duplicate decision | Returned as `duplicate`; nothing is written |
| Decision for an application that can't accept one | Rejected, with the current status in the reason |
| Unexpected exception in the endpoint | Rolled back, 500 returned, error logged |

Partner rejections and send failures go to the **Integration Exceptions** queue. Its members and the group in `Alert_Group__c` receive one in-app notification and one email per run.

---

## Scale and governor limits

| Requirement | Approach |
|---|---|
| Send 1,000 waiting applications | Batch Apex with scope 50: 20 executes, each with its own limits and one callout. Chained Queueables would hit Developer Edition's chain depth limit, and one transaction allows only 120 s of callouts in total |
| Accept 200 decisions in one request | A fixed number of queries and bulk DML regardless of size. The test asserts fewer than 30 queries and 30 DML statements for 200 decisions |
| Never send an application twice | The claim locks rows with `FOR UPDATE`, re-reads them under the lock, and moves only those still Ready to Queued with its batch key before any callout. A concurrent run claims nothing. The per-batch Idempotency-Key covers retries after a timeout |
| Measurement | Every send execute, run summary and inbound request writes a limits snapshot (SOQL, rows, DML, CPU, heap, callouts) to `Integration_Log__c` |

---

## Security

- **Endpoint:** OAuth client credentials as the integration user (any other user gets 403), plus an HMAC-SHA256 signature over the raw body with a 5-minute window and a constant-time comparison.
- **No secrets in source.** The API URL and key are in the Named Credential and External Credential, the signing secret is in a protected custom setting, and local test values are in a gitignored `.env.local`.
- **SSN, EIN and date of birth** are Classic Encrypted fields, masked on screen. Only `FundMate_Admin` has View Encrypted Data.
- **Logs never contain SSNs, EINs, dates of birth, bank figures or keys.** Messages pass through `IntegrationLogger.redact()`, and logs are purged after 90 days.
- **Applications are private.** Specialists see their own applications and those in their queues. Admin and Integration have View All.
- **Status is read-only for specialists.** Only the Send action and the integration change it, so nobody can approve an application by hand.
- **Sharing is explicit.** User-facing code (the Send action, the offer controller) runs in user mode. Eleven classes run without sharing, each for the reason below.

### Classes that run without sharing

| Class | Reason |
|---|---|
| `FundingApplicationTriggerHandler` | Validation must see the whole business (owners, statements) whoever presses Send |
| `UnderwritingClaimService` | Must lock and claim every Ready application, including queue-owned private records |
| `UnderwritingSendBatch` | Sends applications claimed for any user; touches only records carrying its batch key |
| `UnderwritingBatchSender` | Writes the API result back to each claimed application |
| `UnderwritingRetryJob` | Resends a batch after the original request; touches only that batch's applications |
| `UnderwritingRetryScheduler` | Starts a retry for waits over 10 minutes; holds only the batch's ids and key |
| `DecisionProcessor` | Runs as the integration user after OAuth and signature checks; updates the application each decision names |
| `IntegrationLogger` | A log must be written whatever the running user can see |
| `IntegrationLogEventHandler` | Stores log events as the Automated Process user |
| `SendFailureAlertService` | Reads owners and queue members to alert them |
| `IntegrationLogPurge` | Deletes expired logs for every user |

### GLBA Safeguards Rule

| Safeguard | Implementation |
|---|---|
| Encryption | SSN, EIN and date of birth are Classic Encrypted fields, masked on screen |
| Access control | Private applications; three least-privilege permission sets; only FundMate_Admin can view encrypted data; Status read-only for specialists |
| Data in transit | HTTPS only, through the Named Credential; inbound requests need the integration user's token and a valid signature |
| Secrets | API key in an External Credential, signing secret in a protected custom setting |
| Logging | `IntegrationLogger.redact()` masks SSNs, EINs, dates of birth, deposit totals, NSF counts, keys and signatures |
| Monitoring | Every send, retry, rejected signature and error is logged with a limits snapshot; field history on Status; decisions and superseded offers are kept as an audit trail |
| Retention | `IntegrationLogPurge` runs nightly and deletes logs older than `Log_Retention_Days__c` (default 90). Platform event messages expire after 72 hours |

---

## Configuration

`Integration_Setting__mdt.Default`:

| Field | Default | Meaning |
|---|---|---|
| Named Credential / Batch Path | `Underwriting_API` / `/v1/applications/batch` | Callout target |
| Batch Size | 50 | Applications per callout (capped at 50) |
| Max Attempts | 5 | Attempts before Send Failed |
| Backoff Base / Max Backoff (s) | 30 / 3600 | Exponential backoff with full jitter |
| Callout Timeout (ms) | 20000 | Per callout |
| Signature / Timestamp Header | `X-Signature` / `X-Timestamp` | Inbound signing headers |
| Signature Tolerance (s) | 300 | Replay window |
| Minimum Statements / Max Statement Age | 3 / 3 months | Validation |
| Minimum Owner Percentage | 20 | Owners sent with the application |
| Revenue Minimum | 10000 | Flag threshold |
| Min / Max Term Months | 3 / 18 | Offer terms accepted |
| Decision Accepting Statuses | `Acknowledged,Needs More Info` | Applications that can take a decision |
| Max Decisions Per Request | 500 | Inbound cap |
| Send Enabled | true | Kill switch |
| Alert Group | `Integration_Admins` | Receives send-failure alerts, with the owner |
| Log Retention Days | 90 | Logs older than this are purged nightly |

`Payload_Field_Map__mdt`: one record per request key (section, JSON key, source object and field, required flag, optional regex and message).

`Routing_Rule__mdt`: status, amount range, queue and priority. Default rules:
- Approved up to $250,000 → Funding Specialists
- Approved over $250,000 → Senior Funding Specialists
- Needs More Info → Document Collection
- Declined → Declined Review
- Rejected by the partner → Integration Exceptions
- Send Failed → Integration Exceptions

---

## Questions and assumptions

Three questions were sent to Deepak Rayapati on November 3, 2026, and answered on November 4:

| Question | Answer |
|---|---|
| How is each request signed? | Hex HMAC-SHA256 in `X-Signature` over `X-Timestamp + "." + body`; older than 5 minutes is rejected; 401 when missing, wrong or too old |
| Does the batch endpoint accept an idempotency key? | Yes: reuse the same `Idempotency-Key` on every retry of a batch; the partner ignores a repeated key for 24 hours |
| Which queues exist, and what decides routing? | One queue per decision, approvals over $250,000 to Senior Funding Specialists, plus an **Integration Exceptions** queue for partner rejections and send failures |

Assumptions:

1. Every retry resends the same applications with the same key, however long the wait. A user resend, or an application missing from a 2xx response, gets a new key.
2. Applications that fail validation stay in Salesforce as `Validation Failed` and are never sent.
3. Bank statements belong to the business. The application snapshots the latest three when it is created and when it is submitted.
4. Applications need three consecutive monthly statements, the latest within the last 3 months.
5. Owners with 20% or more ownership are sent. Total ownership can't exceed 100%.
6. Time in business is sent in whole months, calculated from `Business_Start_Date__c`.
7. Salesforce sets no funding limit; underwriting decides. Offer terms must be 3 to 18 months, matching FundMate's products.
8. Only Acknowledged and Needs More Info applications can take a decision. A new decision after Needs More Info marks earlier offers Superseded and keeps them.
9. The API needs the full SSN. It is sent only through the Named Credential.
10. Daily payments assume 21 business days a month for the payment count and APR estimate.
11. The mock API simulates failures from the data, because Workers are stateless.

---

## Project layout

```
force-app/main/default/
  classes/          Apex: services, endpoint, batch, tests
  triggers/         One trigger per object, logic in handler classes
  flows/            New_Funding_Application, Send_to_Underwriting, Route_Decided_Funding_Application, Bank_Statement_Defaults
  lwc/              offerComparison, fundmateFields
  objects/          Custom objects, fields, Custom Metadata types, platform event, protected setting
  customMetadata/   Default settings, field map, routing rules
  namedCredentials/ externalCredentials/   Underwriting API connection
  permissionsets/   Admin, Funding Specialist, Integration
  customPermissions/ Post Underwriting Decisions (integration user only)
  queues/ groups/   Five queues and the Integration Admins group
org-config/         Partner connected app template
mock-api/           Cloudflare Worker mock of the Underwriting API
scripts/            send-decisions.mjs, create-partner-app.sh, org setup and seed scripts, CI checker
data/decisions/     Sample decision payloads
.github/workflows/  CI
```

---

## CI and packaging

### CI

`.github/workflows/ci.yml` runs on every push to `main`. It creates a scratch org from the Dev Hub, deploys, assigns `FundMate_Admin`, runs all local tests and fails below 85% coverage. It needs the Dev Hub's auth URL in the `SFDX_AUTH_URL` repository secret:

```bash
sf org display --target-org <devhub> --verbose --json | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>process.stdout.write(JSON.parse(s).result.sfdxAuthUrl))" | gh secret set SFDX_AUTH_URL
```

### Unlocked package

`force-app` is the **FundMate Underwriting** unlocked package (no namespace), including the queues and group. Version 1.0.0 (`04tbm000000vSafAAE`) was built with code coverage checked.

```bash
# Install
sf package install --package 04tbm000000vSafAAE --target-org <alias> --wait 30

# Build a new version
sf package version create --package "FundMate Underwriting" --installation-key-bypass --code-coverage --wait 60
```

After installing, follow Setup steps 2 to 6.
