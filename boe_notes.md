```
Subject: Entity Team — Integration Approach for EAG + BOE (Pre-Meeting Summary)

Hi Team,

Ahead of tomorrow's meeting, I wanted to outline how the Entity team plans to integrate with BOE through the EAG gateway layer. This should help frame the discussion and surface any blockers early.

Integration Overview

The Entity application needs to programmatically run BOE reports and retrieve the results for display within our application. Rather than having end users access BOE directly, Entity will consume BOE's REST services through the EAG API gateway — EAG handles the traffic management, mTLS, and authorization between the two systems.

The high-level flow:
  Entity Application → EAG Gateway (mTLS) → BOE REST Services → Oracle

BOE Endpoints We Need Access To

We plan to use the Raylight REST API under /biprws for report execution. Specifically:

  • POST /biprws/logon/long — Authentication and session token
  • GET /biprws/raylight/v1/documents/{docId} — Open a report document
  • PUT /biprws/raylight/v1/documents/{docId}/parameters — Set report prompt values
  • PUT /biprws/raylight/v1/documents/{docId}/dataproviders — Refresh/execute the report
  • GET /biprws/raylight/v1/documents/{docId}/reports/{reportId} — Retrieve results as JSON

For reports with longer execution times (especially those hitting the larger Oracle views), we may also need the scheduling endpoints under /biprws/raylight/v1/documents/{docId}/schedules to support asynchronous execution.

Questions for the BOE Team

These are the items we'd like to work through in tomorrow's session:

  1. Authentication model — We need a service account that can authenticate via /logon/long through EAG. Is the BOE team able to provision a dedicated service account for this purpose, or should we go through the SSO team for an Enterprise account?

  2. X-SAP-LogonToken — Our calls to Raylight depend on this header being passed through EAG transparently. Has the BOE team worked with EAG before, or is this the first time BOE APIs are being exposed through the gateway?

  3. Report-level security — When we call BOE via a service account, how does BOE enforce report-level access control? Does the service account need specific folder/report permissions configured in CMC, or is there a trusted authentication mechanism we should use?

  4. Long-running reports — Some of the reports we need to consume hit complex Oracle views. Does BOE's Raylight API support an async schedule/poll/retrieve pattern, or do we need to use the BOE Java SDK scheduling APIs for that?

  5. Document IDs — We'll need the SI_ID or CUID for each report we plan to consume, across environments (dev, test, prod). Can the BOE team provide a mapping?

  6. Capacity — What's the concurrent report execution capacity on the BOE Job Server? We want to make sure our call volume doesn't impact existing BOE users.

EAG Onboarding Status

We're working on the EAG intake form and onboarding questionnaire to meet the April 22 deadline for Drop 5. The BOE team will need to complete the Provider Details tab in the OBQ and submit the Swagger file for the Raylight API. Happy to walk through the form together if that's helpful.

Looking forward to the discussion tomorrow.

Thanks,
Santosh
```
