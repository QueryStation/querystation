# QueryStation

> The central command layer for SOQL, SOSL, and GraphQL queries in Salesforce.

---

## The Problem

Every Salesforce org has the same story.

A business team needs one field added to a data pipeline.
Thirty seconds to type. Three weeks to deploy.

The query goes through code review, sandbox deployment,
QA testing, CAB approval, and a Friday night production
window — for a change to a SELECT statement.

The query is not logic. It is not business rules.
It is just — what data do I need today.

And today's answer is different from last quarter's answer.

---

## What QueryStation Does

QueryStation separates your query from your code.

- Your **Apex owns the logic** — stable, rarely changes, deserves a deployment
- **QueryStation owns the query** — changes constantly, should never need a deployment

Your business team changes what data they fetch — new fields,
new relationships, new filters — by editing a record.

No ticket. No developer. No three week wait.

---

## Why Not Custom Metadata?

Custom Metadata is the obvious answer. But it has a hard limit:

**Text fields on Custom Metadata Types max out at 255 characters.**

A real world relationship query like this:

```apex
SELECT Amount, Id, Name,
    (SELECT Quantity, ListPrice,
        PricebookEntry.UnitPrice,
        PricebookEntry.Name,
        PricebookEntry.Product2.Family
    FROM OpportunityLineItems)
FROM Opportunity
WHERE StageName = 'Prospecting'
```

That is over 300 characters. Custom Metadata cannot store it.

QueryStation uses a Long Text Area — **131,072 characters.**
No real query will ever hit that limit.

Additionally Custom Metadata:
- Is buried 5 clicks deep in Setup
- Requires Modify All Data or Customize Application permission
- Has no access control per query
- Has no injection protection
- Has no service API — you build that yourself every time

---

## The Anchor Pattern

Not all fields are equal.

**Anchor fields** — `Id`, `Name`, `Amount`, `StageName` —
are the fields your Apex logic depends on. They are stable.
They change once every few years. When they do change,
everyone knows it is a planned architectural decision
with downstream consequences. A deployment is justified.

**Query fields** — everything else — reflect your evolving
business requirements. New product lines, new metrics,
new relationships, new compliance fields. These change
every week. A deployment is never justified for these.

```apex
SELECT
    Id, Name, Amount,              // Anchor — Apex owns these
    (SELECT
        Quantity,                  // Query fields — QueryStation owns these
        ListPrice,                 // Change freely, no deployment needed
        PricebookEntry.Name,
        PricebookEntry.Product2.Family,
        Competitor__c,
        Deal_Risk_Score__c
    FROM OpportunityLineItems)
FROM Opportunity
```

**Lock your Apex to Id and Name.
Let QueryStation own everything else.**

---

## What This Means In Practice

90% of your data pipeline changes become a record edit.

The 10% that genuinely need a deployment are architectural
decisions your business already planned for.

---

## Who This Is For

| Role | Why QueryStation matters |
|---|---|
| Salesforce Architect | Single governed layer for every dynamic query in the org |
| IT Director | Eliminate unnecessary deployments and their associated risk |
| Sales Ops | Change pipeline data without raising a ticket |
| Revenue Ops | Forecast fields change every quarter — now that is a record edit |
| ISV Publisher | Ship one package, support infinite customer schemas |
| Consultancy | Implement once, reuse across every client project |

---

## Features

- **Centralized query storage** — every dynamic query in one place, visible and governed
- **Parameterized bind variables** — injection-safe named parameters with no SOQL injection risk
- **Access gates** — Custom Permission and Permission Set enforcement per query
- **Three execution modes:**
  - `execute()` — returns full result set
  - `executeForEach()` — streams 200-record chunks, keeps heap flat for large data sets
  - `getQueryLocator()` — returns Database.QueryLocator for Batch Apex
- **Transaction-scoped caching** — vault records cached per transaction, no repeated SOQL
- **Field-agnostic consumption** — use `getPopulatedFieldsAsMap()` to write Apex that never references a field name directly

---

## Installation

### Option 1 — Deploy via SFDX

```bash
git clone https://github.com/QueryStation/querystation.git
cd querystation
sf project deploy start
```

### Option 2 — Copy the files

Copy these files into your org:

```
force-app/main/default/classes/QueryStationService.cls
force-app/main/default/classes/QueryStationService.cls-meta.xml
force-app/main/default/objects/QueryStation__c/
```

---

## Quick Start

### Step 1 — Create a QueryStation record

| Field | Value |
|---|---|
| Query Key | `Get Accounts By Industry` |
| Query Text | `SELECT Id, Name, Industry, Rating FROM Account WHERE Industry = :industry` |
| Status | Active |

### Step 2 — Execute it from Apex

```apex
List<SObject> results = QueryStationService.execute(
    'Get Accounts By Industry',
    new Map<String, Object>{ 'industry' => 'Technology' }
);
```

That is it. Change the query on the record — the Apex never changes.

---

## Relationship Query Example

The real power of QueryStation is complex relationship queries.

**Create a QueryStation record:**

```
Query Key: Get Opportunities With Line Items
Query Text:
SELECT Id, Name, Amount, StageName,
    (SELECT Quantity, ListPrice,
        PricebookEntry.Name,
        PricebookEntry.Product2.Family
    FROM OpportunityLineItems)
FROM Opportunity
WHERE StageName = 'Prospecting'
```

**Execute it:**

```apex
List<SObject> opps = QueryStationService.execute(
    'Get Opportunities With Line Items'
);
```

Tomorrow your business team needs `Competitor__c` and
`Deal_Risk_Score__c` added to the line items.

They edit the QueryStation record. No Apex change.
No deployment. Done in two minutes.

---

## Field-Agnostic Consumption

Write Apex that never breaks when the query changes:

```apex
List<SObject> results = QueryStationService.execute(
    'Get Opportunities With Line Items'
);

for (SObject record : results) {
    Map<String, Object> fields =
        record.getPopulatedFieldsAsMap();

    // No field names anywhere in this Apex
    // Add or remove fields from the query —
    // this code never needs updating
    for (String fieldName : fields.keySet()) {
        System.debug(fieldName + ': ' + fields.get(fieldName));
    }
}
```

---

## Batch Apex Example

```apex
public class OpportunityReportBatch
    implements Database.Batchable<SObject> {

    public Database.QueryLocator start(
        Database.BatchableContext bc) {
        return QueryStationService.getQueryLocator(
            'Get Opportunities With Line Items'
        );
    }

    public void execute(
        Database.BatchableContext bc,
        List<SObject> scope) {
        for (SObject record : scope) {
            // Process records
            // Change the query on the QueryStation record
            // This Apex never changes
        }
    }

    public void finish(Database.BatchableContext bc) {}
}
```

---

## Access Control

QueryStation has three access gates evaluated in sequence:

**Gate 1 — Record visibility**
Enforced by Salesforce sharing rules on the
QueryStation__c object. Configure OWD and sharing
rules in Setup.

**Gate 2 — Custom Permission**
If `Required_Custom_Permission__c` is set, the running
user must hold that Custom Permission.

**Gate 3 — Permission Set**
If `Allowed_Permission_Sets__c` is set, the running user
must have at least one matching Permission Set assigned.

Batch Apex skips Gates 2 and 3 — no user session exists
in that context.

---

## Roadmap

| Feature | Status |
|---|---|
| SOQL support | Available now |
| Parameterized bind variables | Available now |
| Access gates | Planned |
| Batch Apex support | Planned |
| Query versioning | Planned |
| Audit log | Planned |
| Query testing UI | Planned |
| SOSL support | Planned |
| GraphQL support | Planned |
| AppExchange managed package | Planned |

---

## Contributing

QueryStation is open source and community driven.

If you have used this in your org — we would love to
hear how. Open an issue, start a discussion, or submit
a pull request.

Areas where contributions are most welcome:
- Additional execution modes
- Query validation
- Test coverage
- Documentation and examples
- LWC query builder UI

---

## License

MIT — free to use, modify, and distribute.

---

## Built By

Salesforce practitioners who got tired of raising
deployment requests for SELECT statements.

If this solves a problem you have — star the repo,
share it with your team, and tell us what you need next.
