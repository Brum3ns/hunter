package validation

import "encoding/json"

var validationResultSchema = json.RawMessage(`{
    "type":"object",
    "additionalProperties":false,
    "required":["id"],
    "properties":{"id":{"type":"string","minLength":1,"maxLength":255,"pattern":"^[A-Za-z0-9][A-Za-z0-9._:-]*$"}}
  }`)

var whiterabbitSchema = json.RawMessage(`{
    "type":"object",
    "additionalProperties":false,
    "required":["draft"],
    "properties":{"draft":{
      "type":"object","additionalProperties":false,"required":["name","commands"],
      "properties":{
        "name":{"type":"string","minLength":1,"maxLength":200},
        "kind":{"type":"string","maxLength":40},
        "description":{"type":"string","maxLength":4000},
        "commands":{"type":"array","maxItems":50,"items":{
          "type":"object","additionalProperties":false,"required":["command","args"],
          "properties":{
            "command":{"type":"string","minLength":1,"maxLength":255},
            "args":{"type":"array","maxItems":200,"items":{"type":"string","maxLength":4096}},
            "operator":{"type":"string","maxLength":4}
          }
        }}
      }
    }}
  }`)

var ansibleSchema = json.RawMessage(`{
    "type":"object",
    "additionalProperties":false,
    "required":["draft"],
    "properties":{"draft":{
      "type":"object","additionalProperties":false,"required":["name","source"],
      "properties":{
        "name":{"type":"string","minLength":1,"maxLength":200},
        "source":{"type":"string","minLength":1,"maxLength":65536}
      }
    }}
  }`)
