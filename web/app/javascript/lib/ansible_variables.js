export function formTypedValue(type, rawValue) {
  if (type === "number") {
    const number = Number(rawValue)
    return rawValue.trim() !== "" && Number.isFinite(number) ? number : rawValue
  }
  if (type === "boolean") {
    if (rawValue === "true") return true
    if (rawValue === "false") return false
  }
  return rawValue
}

export function variablePayload(variable, position) {
  const payload = {
    name: variable.name,
    value_type: variable.valueType,
    secret: variable.secret,
    position,
  }
  if (!(variable.secret && variable.configured && variable.rawValue === "")) {
    payload.value = formTypedValue(variable.valueType, variable.rawValue)
  }
  return payload
}
