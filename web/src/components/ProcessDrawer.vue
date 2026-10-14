<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useI18n } from 'vue-i18n'
import {
  NDrawer, NDrawerContent, NTabs, NTabPane, NDescriptions, NDescriptionsItem, NTag,
  NButton, NSpace, NEmpty, NSpin, NInput, NCode, NAlert, NIcon, useDialog, useMessage,
} from 'naive-ui'
import { RefreshOutline, SkullOutline, SendOutline, ChatbubblesOutline } from '@vicons/ionicons5'
import { client } from '../api/ws'
import { errorText } from '../api/errors'
import type { ProcessDetail } from '../api/types'
import { formatBytes, formatNumber } from '../api/format'
import { useSettings } from '../stores/settings'
import Term from './Term.vue'

const props = defineProps<{ node: string; pid: string | null }>()
const emit = defineEmits<{ 'update:pid': [string | null]; killed: [] }>()

const { t } = useI18n()
const settings = useSettings()
const route = useRoute()
const router = useRouter()
const dialog = useDialog()
const message = useMessage()
const detail = ref<ProcessDetail | null>(null)
const loading = ref(false)
const error = ref<string | null>(null)
const state = ref<string | null>(null)
const stateLoading = ref(false)
const sendText = ref('')
const history = ref<string[]>([])

const show = computed({
  get: () => props.pid !== null,
  set: (v) => { if (!v) { history.value = []; emit('update:pid', null) } },
})

async function load() {
  if (!props.pid) return
  loading.value = true
  error.value = null
  try {
    detail.value = await client.request<ProcessDetail>('process.info', { node: props.node, pid: props.pid })
  } catch (e) {
    detail.value = null
    error.value = errorText(e)
  } finally {
    loading.value = false
  }
}

watch(() => props.pid, () => {
  state.value = null
  sendText.value = ''
  void load()
}, { immediate: true })

function open(ref: string) {
  if (ref.startsWith('#Port')) {
    void router.push({ path: '/ports', query: { node: route.query.node, port: ref } })
    return
  }
  if (!ref.startsWith('<') || ref === props.pid) return
  if (props.pid) history.value.push(props.pid)
  emit('update:pid', ref)
}

function traceIt() {
  const pid = props.pid
  if (pid) void router.push({ path: '/trace', query: { node: route.query.node, target: pid } })
}

function back() {
  const prev = history.value.pop()
  if (prev) emit('update:pid', prev)
}

async function readState() {
  stateLoading.value = true
  try {
    state.value = await client.request<string>('process.state', { node: props.node, pid: props.pid })
  } catch (e) {
    message.error(t('procs.drawer.state_failed', { err: errorText(e) }))
  } finally {
    stateLoading.value = false
  }
}

function kill() {
  const pid = props.pid
  dialog.error({
    title: t('procs.kill.title'),
    content: t('procs.kill.content', { pid }),
    positiveText: t('procs.kill.ok'),
    negativeText: t('procs.cancel'),
    onPositiveClick: async () => {
      try {
        await client.request('process.kill', { node: props.node, pid })
        message.success(t('procs.kill.done', { pid }))
        emit('killed')
        await load()
      } catch (e) {
        message.error(errorText(e))
      }
    },
  })
}

function send() {
  const text = sendText.value.trim()
  if (!text) return
  dialog.warning({
    title: t('procs.drawer.send_title'),
    content: t('procs.drawer.send_confirm', { pid: props.pid, text }),
    positiveText: t('procs.drawer.send'),
    negativeText: t('procs.cancel'),
    onPositiveClick: async () => {
      try {
        await client.request('process.send', { node: props.node, pid: props.pid, message: text })
        message.success(t('procs.drawer.sent'))
        sendText.value = ''
        await load()
      } catch (e) {
        message.error(t('procs.drawer.send_failed', { err: errorText(e) }))
      }
    },
  })
}

const bytes = (words: number) => formatBytes(words * (detail.value?.word_size ?? 8))
</script>

<template>
  <NDrawer v-model:show="show" :width="720" placement="right">
    <NDrawerContent :native-scrollbar="false" closable>
      <template #header>
        <NSpace align="center" :size="8">
          <NButton v-if="history.length" size="tiny" quaternary @click="back">{{ t('procs.drawer.back') }}</NButton>
          <span class="mono">{{ pid }}</span>
          <NTag v-if="detail?.name" size="small" type="primary" :bordered="false">{{ detail.name }}</NTag>
          <NTag v-if="detail" size="small" :bordered="false">{{ detail.status }}</NTag>
          <NButton quaternary circle size="small" :loading="loading" @click="load">
            <template #icon><NIcon :component="RefreshOutline" /></template>
          </NButton>
        </NSpace>
      </template>

      <NSpin v-if="loading && !detail" style="width: 100%; padding: 60px 0" />
      <NEmpty v-else-if="error === 'not_found'" :description="t('procs.drawer.exited')" style="padding: 60px 0" />
      <NAlert v-else-if="error" type="error">{{ error }}</NAlert>
      <NTabs v-else-if="detail" type="line" animated>
        <NTabPane name="overview" :tab="t('procs.drawer.tabs.overview')">
          <NDescriptions :column="2" label-placement="left" size="small" bordered>
            <NDescriptionsItem><template #label><Term label="初始调用" /></template><span class="mono">{{ detail.initial_call }}</span></NDescriptionsItem>
            <NDescriptionsItem><template #label><Term label="当前函数" /></template><span class="mono">{{ detail.current_function }}</span></NDescriptionsItem>
            <NDescriptionsItem><template #label><Term label="Reductions" /></template>{{ formatNumber(detail.reductions) }}</NDescriptionsItem>
            <NDescriptionsItem><template #label><Term label="消息队列" /></template>{{ formatNumber(detail.message_queue_len) }}</NDescriptionsItem>
            <NDescriptionsItem><template #label><Term label="内存" /></template>{{ formatBytes(detail.memory) }}</NDescriptionsItem>
            <NDescriptionsItem><template #label><Term label="堆 / 总堆" /></template>{{ bytes(detail.heap_size) }} / {{ bytes(detail.total_heap_size) }}</NDescriptionsItem>
            <NDescriptionsItem><template #label><Term label="栈" /></template>{{ bytes(detail.stack_size) }}</NDescriptionsItem>
            <NDescriptionsItem><template #label><Term label="优先级" /></template>{{ detail.priority }}</NDescriptionsItem>
            <NDescriptionsItem><template #label><Term label="trap_exit" /></template>{{ t(detail.trap_exit ? 'procs.drawer.yes' : 'procs.drawer.no') }}</NDescriptionsItem>
            <NDescriptionsItem><template #label><Term label="Group leader" /></template>
              <a class="mono link" @click="open(detail.group_leader)">{{ detail.group_leader }}</a>
            </NDescriptionsItem>
          </NDescriptions>
          <div v-for="g in [
            { title: 'Links', items: detail.links },
            { title: 'Monitors', items: detail.monitors },
            { title: 'Monitored by', items: detail.monitored_by },
          ]" :key="g.title" class="group">
            <div class="group-title"><Term :label="g.title" /> <span class="count">{{ g.items.length }}</span></div>
            <NSpace v-if="g.items.length" :size="6">
              <NTag v-for="r in g.items" :key="r" size="small" class="mono"
                    :class="{ clickable: r.startsWith('<') || r.startsWith('#Port') }" @click="open(r)">{{ r }}</NTag>
            </NSpace>
            <div v-else class="none">{{ t('procs.drawer.none') }}</div>
          </div>
          <div class="group">
            <div class="group-title">{{ t('procs.drawer.gc') }}</div>
            <table class="kv">
              <tr v-for="g in detail.garbage_collection" :key="g.key">
                <td class="k">{{ g.key }}</td>
                <td class="mono gc-v">{{ g.value }}</td>
              </tr>
            </table>
          </div>
        </NTabPane>

        <NTabPane name="messages" :tab="t('procs.drawer.tabs.messages', { n: detail.message_queue_len })">
          <NAlert v-if="detail.messages === 'truncated'" type="warning">
            {{ t('procs.drawer.truncated', { n: formatNumber(detail.message_queue_len) }) }}
          </NAlert>
          <NEmpty v-else-if="!detail.messages.length" :description="t('procs.drawer.queue_empty')" />
          <div v-else class="terms">
            <NCode v-for="(m, i) in detail.messages" :key="i" :code="m" word-wrap class="term" />
          </div>
        </NTabPane>

        <NTabPane name="dictionary" :tab="t('procs.drawer.tabs.dictionary', { n: detail.dictionary.length })">
          <NEmpty v-if="!detail.dictionary.length" :description="t('procs.drawer.dict_empty')" />
          <table v-else class="kv">
            <tr v-for="(d, i) in detail.dictionary" :key="i">
              <td class="mono k">{{ d.key }}</td>
              <td><NCode :code="d.value" word-wrap /></td>
            </tr>
          </table>
        </NTabPane>

        <NTabPane name="stack" :tab="t('procs.drawer.tabs.stack')">
          <table class="kv">
            <tr v-for="(f, i) in detail.stacktrace" :key="i">
              <td class="mono">{{ f.mfa }}</td>
              <td class="mono loc">{{ f.location ?? '' }}</td>
            </tr>
          </table>
        </NTabPane>

        <NTabPane name="state" :tab="t('procs.drawer.tabs.state')">
          <i18n-t keypath="procs.drawer.state_hint" tag="p" class="hint" scope="global">
            <template #fn><code>sys:get_state/2</code></template>
          </i18n-t>
          <NButton :loading="stateLoading" @click="readState">{{ t('procs.drawer.read_state') }}</NButton>
          <NCode v-if="state" :code="state" word-wrap class="term" style="margin-top: 12px" />
        </NTabPane>

        <NTabPane v-if="!settings.readOnly" name="actions" :tab="t('procs.drawer.tabs.actions')">
          <div class="group-title">{{ t('common.trace') }}</div>
          <p class="none" style="margin: 0 0 8px">{{ t('procs.drawer.trace_intro') }}</p>
          <NButton @click="traceIt">
            <template #icon><NIcon :component="ChatbubblesOutline" /></template>
            {{ t('procs.drawer.trace_button') }}
          </NButton>
          <div class="group-title" style="margin-top: 24px">{{ t('procs.drawer.send_title') }}</div>
          <NInput v-model:value="sendText" type="textarea" class="mono"
                  :placeholder="t('procs.drawer.send_placeholder')" :autosize="{ minRows: 2, maxRows: 6 }" />
          <NButton style="margin-top: 8px" :disabled="!sendText.trim()" @click="send">
            <template #icon><NIcon :component="SendOutline" /></template>
            {{ t('procs.drawer.send') }}
          </NButton>
          <div class="group-title" style="margin-top: 24px">{{ t('procs.drawer.kill_title') }}</div>
          <NButton type="error" secondary @click="kill">
            <template #icon><NIcon :component="SkullOutline" /></template>
            exit(Pid, kill)
          </NButton>
        </NTabPane>
      </NTabs>
    </NDrawerContent>
  </NDrawer>
</template>

<style scoped>
.group {
  margin-top: 20px;
}
.group-title {
  font-weight: 600;
  margin-bottom: 8px;
}
.count, .none, .hint, .loc {
  opacity: 0.55;
}
.clickable, .link {
  cursor: pointer;
}
.link:hover, .clickable:hover {
  text-decoration: underline;
}
.terms {
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.term {
  font-size: 12px;
}
.kv {
  width: 100%;
  border-collapse: collapse;
  font-size: 13px;
}
.kv td {
  padding: 6px 8px;
  vertical-align: top;
  border-bottom: 1px solid rgba(128, 128, 128, 0.15);
}
.gc-v {
  word-break: break-all;
}
.kv .k {
  width: 35%;
  word-break: break-all;
}
</style>
