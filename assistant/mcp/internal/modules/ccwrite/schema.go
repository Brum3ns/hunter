package ccwrite

import "encoding/json"

var templateSchema = json.RawMessage(`{
    "type":"object",
    "additionalProperties":false,
    "required":["template"],
    "properties":{"template":{
      "type":"object","additionalProperties":false,"required":["name","kind","commands"],
      "properties":{
        "name":{"type":"string","minLength":1,"maxLength":200},
        "kind":{"type":"string","enum":["cmdscript","workflow"]},
        "description":{"type":"string","maxLength":4000},
        "commands":{"type":"array","maxItems":50,"items":{
          "type":"object","additionalProperties":false,"required":["command"],
          "properties":{
            "command":{"type":"string","minLength":1,"maxLength":255},
            "operator":{"type":"string","maxLength":4},
            "args":{"type":"array","maxItems":200,"items":{"type":"string","maxLength":4096}}
          }
        }}
      }
    }}
  }`)

var playbookSchema = json.RawMessage(`{
    "type":"object",
    "additionalProperties":false,
    "required":["playbook"],
    "properties":{"playbook":{
      "type":"object","additionalProperties":false,"required":["name","source"],
      "properties":{
        "name":{"type":"string","minLength":1,"maxLength":200},
        "source":{"type":"string","minLength":1,"maxLength":65536}
      }
    }}
  }`)
