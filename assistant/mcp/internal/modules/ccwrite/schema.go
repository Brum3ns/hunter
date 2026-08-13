package ccwrite

import "encoding/json"

const commandProperties = `
  "commands":{"type":"array","minItems":1,"maxItems":50,"items":{
    "type":"object","additionalProperties":false,"required":["command"],
    "properties":{
      "command":{"type":"string","minLength":1,"maxLength":255},
      "operator":{"type":"string","enum":["","|","&&","||"]},
      "args":{"type":"array","maxItems":200,"items":{"type":"string","maxLength":4096}}
    }
  }}`

const templateProperties = `
  "name":{"type":"string","minLength":1,"maxLength":200},
  "kind":{"type":"string","enum":["cmdscript","workflow"]},
  "tags":{"type":"array","maxItems":50,"items":{"type":"string","maxLength":200}},
  "description":{"type":"string","maxLength":4000},
  "output":{"type":"string","maxLength":4000},
  ` + commandProperties + `,
  "target":{"type":"object","additionalProperties":false,
    "properties":{
      "type":{"type":"string","maxLength":100},
      "separator":{"type":"string","maxLength":20},
      "output":{"type":"string","maxLength":4000}
    }}
`

var templateSchema = json.RawMessage(`{
  "type":"object","additionalProperties":false,"required":["template"],
  "properties":{"template":{
    "type":"object","additionalProperties":false,"required":["name","kind","commands"],
    "properties":{` + templateProperties + `}
  }}
}`)

var templateEditSchema = json.RawMessage(`{
  "type":"object","additionalProperties":false,
  "required":["id","expected_lock_version","changes"],
  "properties":{
    "id":{"type":"integer","minimum":1},
    "expected_lock_version":{"type":"integer","minimum":0},
    "changes":{"type":"object","additionalProperties":false,"minProperties":1,
      "properties":{` + templateProperties + `}}
  }
}`)

const playbookProperties = `
  "name":{"type":"string","minLength":1,"maxLength":200},
  "description":{"type":"string","maxLength":4000},
  "source":{"type":"string","minLength":1,"maxLength":65536},
  "variable_set_ids":{"type":"array","maxItems":100,"uniqueItems":true,
    "items":{"type":"integer","minimum":1}}
`

var playbookSchema = json.RawMessage(`{
  "type":"object","additionalProperties":false,"required":["playbook"],
  "properties":{"playbook":{
    "type":"object","additionalProperties":false,"required":["name","source"],
    "properties":{` + playbookProperties + `}
  }}
}`)

var playbookEditSchema = json.RawMessage(`{
  "type":"object","additionalProperties":false,
  "required":["id","expected_lock_version","changes"],
  "properties":{
    "id":{"type":"integer","minimum":1},
    "expected_lock_version":{"type":"integer","minimum":0},
    "changes":{"type":"object","additionalProperties":false,"minProperties":1,
      "properties":{` + playbookProperties + `}}
  }
}`)

func resultSchema(artifact string) json.RawMessage {
	return json.RawMessage(`{
    "type":"object","additionalProperties":false,"required":["result"],
    "properties":{"result":{
      "type":"object","additionalProperties":false,"required":["correlation_id","` + artifact + `"],
      "properties":{
        "correlation_id":{"type":"string","format":"uuid"},
        "` + artifact + `":{"type":"object","additionalProperties":false,
          "required":["id","name","lock_version"],
          "properties":{
            "id":{"type":"integer","minimum":1},
            "name":{"type":"string","minLength":1,"maxLength":200},
            "lock_version":{"type":"integer","minimum":0}
          }}
      }}
    }
  }`)
}
