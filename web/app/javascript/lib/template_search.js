const DORK_KEYS = new Set(["name", "kind", "tag", "command", "creator"])

export function parseTemplateQuery(query) {
  const raw = String(query || "").trim()
  if (!raw) return null
  try {
    return new QueryParser(tokenize(raw)).parse()
  } catch {
    return fallbackExpression(raw)
  }
}

export function filterTemplates(templates, query) {
  const source = Array.from(templates || [])
  const expression = parseTemplateQuery(query)
  return expression ? source.filter((template) => evaluate(expression, template || {})) : source
}

function tokenize(input) {
  const tokens = []
  let index = 0
  while (index < input.length) {
    if (/\s/.test(input[index])) { index += 1; continue }
    if (input[index] === "(") { tokens.push({ type: "lparen" }); index += 1; continue }
    if (input[index] === ")") { tokens.push({ type: "rparen" }); index += 1; continue }

    let value = ""
    while (index < input.length && !/\s|[()]/.test(input[index])) {
      if (input[index] !== '"') { value += input[index]; index += 1; continue }
      index += 1
      let closed = false
      while (index < input.length) {
        if (input[index] === "\\" && index + 1 < input.length) {
          value += input[index + 1]; index += 2
        } else if (input[index] === '"') {
          closed = true; index += 1; break
        } else {
          value += input[index]; index += 1
        }
      }
      if (!closed) throw new SyntaxError("unterminated quote")
    }

    if (!value) continue
    const operator = value.toUpperCase()
    if (operator === "AND" || operator === "OR") {
      tokens.push({ type: operator.toLowerCase() })
      continue
    }
    const colon = value.indexOf(":")
    const candidate = colon > 0 ? value.slice(0, colon).toLowerCase() : null
    const dorkValue = colon > 0 ? value.slice(colon + 1) : ""
    tokens.push(candidate && DORK_KEYS.has(candidate) && dorkValue
      ? { type: "term", key: candidate, value: dorkValue }
      : { type: "term", key: null, value })
  }
  return tokens
}

class QueryParser {
  constructor(tokens) { this.tokens = tokens; this.position = 0 }

  parse() {
    const expression = this.parseOr()
    if (!expression || this.position !== this.tokens.length) throw new SyntaxError("invalid expression")
    return expression
  }

  parseOr() {
    const children = [this.parseAnd()]
    while (this.peek()?.type === "or") { this.position += 1; children.push(this.parseAnd()) }
    return combine("or", children)
  }

  parseAnd() {
    const children = [this.parsePrimary()]
    while (true) {
      const type = this.peek()?.type
      if (type === "and") { this.position += 1; children.push(this.parsePrimary()) }
      else if (type === "term" || type === "lparen") children.push(this.parsePrimary())
      else break
    }
    return combine("and", children)
  }

  parsePrimary() {
    const token = this.peek()
    if (!token) throw new SyntaxError("missing operand")
    if (token.type === "term") {
      this.position += 1
      return { type: "term", key: token.key, value: token.value }
    }
    if (token.type === "lparen") {
      this.position += 1
      const expression = this.parseOr()
      if (this.peek()?.type !== "rparen") throw new SyntaxError("unmatched parenthesis")
      this.position += 1
      return expression
    }
    throw new SyntaxError("unexpected token")
  }

  peek() { return this.tokens[this.position] }
}

function combine(type, children) {
  if (children.some((child) => !child)) throw new SyntaxError("missing operand")
  return children.length === 1 ? children[0] : { type, children }
}

function fallbackExpression(raw) {
  const words = raw.replace(/[()]/g, " ").replace(/"/g, "").split(/\s+/)
    .filter((word) => word && !/^(?:AND|OR)$/i.test(word))
    .map((value) => ({ type: "term", key: null, value }))
  return words.length ? combine("and", words) : null
}

function evaluate(expression, template) {
  if (expression.type === "and") return expression.children.every((child) => evaluate(child, template))
  if (expression.type === "or") return expression.children.some((child) => evaluate(child, template))
  return matchesTerm(template, expression)
}

function matchesTerm(template, term) {
  const commandValues = Array.from(template.commands || []).flatMap((command) => {
    const args = flatten(command?.args)
    const executable = String(command?.command || "")
    return [executable, ...args, [executable, ...args].join(" ")]
  })
  if (!term.key) {
    return [template.name, template.description, ...(template.tags || []), ...commandValues]
      .some((value) => matchValue(value, term.value, false))
  }
  const fields = {
    name: [template.name], kind: [template.kind], tag: template.tags || [],
    command: commandValues, creator: [template.created_by],
  }
  const exact = ["kind", "tag", "creator"].includes(term.key)
  return fields[term.key].some((value) => matchValue(value, term.value, exact))
}

function flatten(value) {
  if (!Array.isArray(value)) return value == null ? [] : [String(value)]
  return value.flatMap((entry) => flatten(entry))
}

function matchValue(actualValue, queryValue, exact) {
  const actual = String(actualValue || "").toLowerCase()
  const wanted = String(queryValue || "").toLowerCase()
  if (!wanted) return false
  if (!wanted.includes("*")) return exact ? actual === wanted : actual.includes(wanted)
  const source = wanted.split("*")
    .map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
    .join(".*")
  return new RegExp(`^${source}$`, "i").test(actual)
}
