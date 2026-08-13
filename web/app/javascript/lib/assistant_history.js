function findConversationIndex(conversations, id) {
  const normalizedId = String(id)
  return conversations.findIndex((conversation) => String(conversation.id) === normalizedId)
}

export function reorderConversation(conversations, draggedId, targetId, placement) {
  const reordered = [...conversations]
  if (placement !== "before" && placement !== "after") return reordered

  const draggedIndex = findConversationIndex(reordered, draggedId)
  const originalTargetIndex = findConversationIndex(reordered, targetId)
  if (draggedIndex < 0 || originalTargetIndex < 0 || draggedIndex === originalTargetIndex) {
    return reordered
  }

  const [dragged] = reordered.splice(draggedIndex, 1)
  const targetIndex = findConversationIndex(reordered, targetId)
  const insertionIndex = placement === "after" ? targetIndex + 1 : targetIndex
  reordered.splice(insertionIndex, 0, dragged)
  return reordered
}

export function moveConversation(conversations, id, direction) {
  const moved = [...conversations]
  if (direction !== -1 && direction !== 1) return moved

  const index = findConversationIndex(moved, id)
  const destination = index + direction
  if (index < 0 || destination < 0 || destination >= moved.length) return moved

  const [conversation] = moved.splice(index, 1)
  moved.splice(destination, 0, conversation)
  return moved
}

export function conversationIds(conversations) {
  return conversations.map((conversation) => conversation.id)
}
