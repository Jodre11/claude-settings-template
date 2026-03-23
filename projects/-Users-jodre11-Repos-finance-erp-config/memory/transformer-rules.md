# Transformer Rule Execution Details

## Source
`~/Repos/finance-erp/erp/erp-finance-pipeline/erp-transformer.Business/Extensions/TransformerExtensions.cs`

## Execution Order in `RunTransformationOnAccounts`
1. `ApplyAlwaysReplaceFields` — unconditional field sets
2. `ProcessAccounts` — applies CheckFieldConfig via typed TransformerConfig (older path)
3. `SplitFields`
4. `ConcatenateFields`
5. `CheckAndReplaceFields` — applies CheckFieldConfig from raw JArray (primary path)
6. `UpdateDates`

## CheckAndReplaceFields Behaviour
- Iterates `CheckFieldConfig` rules sequentially in array order
- Single `Accounts` object mutated in place — no snapshot of original values
- Each rule's check reads current live state (includes writes from earlier rules)
- All CheckFieldItems within a rule use AND logic

## CheckType Behaviour
- `exact`: case-insensitive, trimmed, full equality
- `contains`: case-insensitive, trimmed, substring match
- Unknown CheckType: falls through to default, does NOT fail — treated as match (latent bug)

## Common Pattern: NN Intermediate Value
- Some configs (e.g. Haven/Coupa/Invoice, Haven/CoupaExtract/Invoice) use "NN" as an intermediate TaxRate
- AP/TX category rules set TaxRate="NN", then a trailing catch-all rule converts NN→"0" for ERPx
- This is intentional — "NN" is a semantic marker, "0" is the final ERPx output
