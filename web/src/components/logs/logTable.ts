// Shared by the live log and the log file tables.

// Rows have one fixed height (each table's style pins it): the virtual
// list sizes its scroll area by it, and rows of another height leave the
// last ones out of reach.
export const ROW_HEIGHT = 36

export const oneLine = (text: string) => text.replace(/\s+/g, ' ').trim()
