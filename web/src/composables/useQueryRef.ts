import { computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'

// A string ref stored in the URL query, so the view can be shared as a link.
export function useQueryRef(name: string) {
  const route = useRoute()
  const router = useRouter()
  return computed<string | null>({
    get: () => {
      const v = route.query[name]
      return typeof v === 'string' && v !== '' ? v : null
    },
    set: (v) => {
      const query = { ...route.query }
      if (v) query[name] = v
      else delete query[name]
      void router.replace({ query })
    },
  })
}
