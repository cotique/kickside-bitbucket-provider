<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { api } from '@wippy-fe/proxy'
import { Icon } from '@iconify/vue'
import type { ModuleStatus } from '../types'

// Bitbucket Connector page: shows module identity and the capabilities this
// module publishes (a kickside.connection provider, a kickside.data:pullable
// pull-request source), from GET /api/v1/bitbucket-provider/status. The
// module owns no persisted rows of its own — the engine owns cursor/lease/
// dedup state for the pull source, so this page is identity-only, not a
// data browser.
const status = ref<ModuleStatus | null>(null)
const loading = ref(true)
const error = ref('')

async function load() {
  loading.value = true
  error.value = ''
  try {
    const { data } = await api.get('/api/v1/bitbucket-provider/status')
    if (!data?.success) throw new Error(data?.error || 'Could not load bitbucket-provider status.')
    status.value = {
      module: String(data.module),
      status: String(data.status),
      capabilities: Array.isArray(data.capabilities) ? data.capabilities.map(String) : [],
    }
  } catch (e) {
    status.value = null
    error.value = e instanceof Error ? e.message : 'Could not load bitbucket-provider status.'
  } finally {
    loading.value = false
  }
}

onMounted(load)
</script>

<template>
  <div class="st">
    <div class="st-head">
      <div class="st-head-icon"><Icon icon="tabler:brand-bitbucket" /></div>
      <div>
        <h1 class="st-title">{{ status?.module ?? 'cotique/bitbucket-provider' }}</h1>
        <p class="st-sub">Bitbucket Cloud connection and pull-request source for Kickside Data Sync.</p>
      </div>
    </div>

    <div v-if="loading" class="st-state">Loading…</div>
    <div v-else-if="error" class="st-state st-error">
      {{ error }}
      <button class="st-retry" type="button" @click="load">Retry</button>
    </div>
    <div v-else class="st-body">
      <div class="st-card">
        <span class="st-count">{{ status?.status ?? 'unknown' }}</span>
        <span class="st-count-label">module status</span>
      </div>
      <ul class="st-caps">
        <li v-for="cap in status?.capabilities ?? []" :key="cap">{{ cap }}</li>
      </ul>
    </div>
  </div>
</template>
