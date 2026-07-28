package targets

import "encoding/json"

var listSchema = json.RawMessage(`{
    "type":"object","additionalProperties":false,
    "properties":{
      "q":{"type":"string","maxLength":200},
      "program":{"type":"string","maxLength":200},
      "status":{"type":"string","maxLength":40},
      "page":{"type":"integer","minimum":1,"maximum":100000},
      "limit":{"type":"integer","minimum":1,"maximum":50}
    }
  }`)

var getSchema = json.RawMessage(`{
    "type":"object","additionalProperties":false,"required":["id"],
    "properties":{"id":{"type":"string","minLength":1,"maxLength":255,"pattern":"^[A-Za-z0-9][A-Za-z0-9._:-]*$"}}
  }`)
