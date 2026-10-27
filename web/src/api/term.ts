import { h } from 'vue'
import Term from '../components/Term.vue'

// Title render function with the glossary tooltip, for table columns and
// card titles. `tip` overrides the glossary when a label means something
// different in that place; `card` names the BEAM Book card to open then.
export const term = (label: string, tip?: string, card?: string) => () => h(Term, { label, tip, card })
