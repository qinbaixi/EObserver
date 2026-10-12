import { h } from 'vue'
import Term from '../components/Term.vue'

// Title render function with the glossary tooltip, for table columns and
// card titles. `tip` overrides the glossary when a label means something
// different in that place.
export const term = (label: string, tip?: string) => () => h(Term, { label, tip })
