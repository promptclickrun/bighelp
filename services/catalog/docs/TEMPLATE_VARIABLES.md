# Template variables (v1)

An agent template in the Template Catalog (`catalog.bighelp.app/v1/catalog.json`, `agents[]`) can declare
variables. When a person starts an agent from the template, the app shows a short form with one field for each
variable. The person completes the fields, and the app puts the values into the template text. The plugin's
template tools use the same rules, so an agent can fill a template for the person.

## Placeholders in the text

- Write a variable as `{{key}}` in `instructions` (the SOUL text). You can also use it in `role` and
  `description`.
- `key` uses lowercase letters, digits and underscores. It starts with a letter and has 40 characters or
  fewer (`^[a-z][a-z0-9_]{0,39}$`). Do not put spaces inside the braces.
- The same key can occur many times. Each occurrence gets the same value.
- Do not use `{{` or `}}` for other text.

## Reserved keys

The app fills these keys. A template uses them, but does not declare them.

- `agent_name`: the name of the agent, from the name field. The form always asks for it, and it is
  always required.
- `user_name`: the name that the person saved in bighelp. If the person did not save a name, the form asks
  for it.

## Declare variables

Put the variables in `variables` on the template entry:

```json
"variables": [
  {"key": "agent_role", "label": "Role", "type": "text", "required": true,
   "example": "Release coordinator", "help": "What this agent does for you, in a few words.", "maxLength": 80},
  {"key": "operating_context", "label": "Where it works", "type": "long_text", "required": false,
   "example": "A two-person studio shipping an iPhone app.", "maxLength": 600,
   "whenEmpty": "General work for the user."},
  {"key": "tone", "label": "Tone", "type": "choice", "options": ["Warm", "Direct", "Playful"], "default": "Direct"}
]
```

The fields of a variable:

| Field | Rule |
|---|---|
| `key` | Required. Use the key rules above. Do not use a reserved key. Each key occurs one time in a template. |
| `label` | Required, 40 characters or fewer. The name of the field in the form. Use plain words. |
| `type` | Required. `text` (one line), `long_text` (many lines), `choice` (one of `options`) or `number`. |
| `required` | Default `true`. If `true`, the person cannot finish the form without a value. |
| `default` | The value that the form shows first. For `choice`, use one of the options. |
| `example` | 120 characters or fewer. The form shows it in grey in the empty field. The app never uses it as a value. |
| `help` | 160 characters or fewer. One short line below the field. |
| `maxLength` | `text`: default 80, maximum 200. `long_text`: default 600, maximum 4000. |
| `options` | `choice` only. 2 to 12 items, each 60 characters or fewer. `allowOther: true` adds a free-text "Other". |
| `min`, `max` | `number` only. |
| `whenEmpty` | Optional variables only, 200 characters or fewer. The app uses this text if the person leaves the field empty. If there is no `whenEmpty`, an empty optional value becomes empty text. |

A template has 12 variables or fewer. The form shows the name field first. Then it shows the variables in the
order of the list.

## Fill the text

1. Trim each value.
2. In `text`, `choice` and `number` values, change each line break to a space. `long_text` values keep their
   line breaks.
3. Remove `{{` and `}}` from each value. The app inserts each value as plain text, as the person typed it.
4. Replace all placeholders in one pass. Thus the app never reads a value as a placeholder.

Sometimes the text has a `{{key}}` that `variables` does not declare and that is not a reserved key. Then the app asks for it.
This occurs in old templates and in templates that a person wrote by hand. The app shows a required one-line
`text` field.
The label comes from the key: "operating_context" becomes "Operating context".

The catalog
refuses these templates when a person submits them and when a reviewer examines them.

The agent profile gets the filled text. No placeholder stays in it.

## Catalog rules (submit, review and seed)

The catalog refuses a template if one of these conditions is true:

- The text uses a key that `variables` does not declare.
- `variables` declares a key that the text does not use.
- `variables` declares a reserved key.
- The template does not obey a limit in this document.

The error tells which field is wrong, for example `{"error": "…", "field": "variables[2].options"}`. If a
placeholder in the text causes the error, `field` is `instructions`, `role` or `description`.

Templates without `variables` work as before. The app fills only the reserved keys in them.
