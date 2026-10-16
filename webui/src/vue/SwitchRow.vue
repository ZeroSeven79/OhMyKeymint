<script setup lang="ts">
/**
 * Switch row built on plain `click` handling.
 *
 * The component library's switch only listens to pointer events
 * (`onPointerdown` / `onPointermove` / `onPointerup` / `onPointercancel`) and
 * has no `click` handler, so on Android WebView a tap that drifts slightly or
 * fires `pointercancel` is silently dropped. This row reacts to `click` and
 * exposes the whole row as the hit area, which matches how the surrounding
 * preference rows already behave.
 */
withDefaults(defineProps<{
  modelValue: boolean
  title: string
  summary?: string
  disabled?: boolean
}>(), {
  summary: '',
  disabled: false,
})

const emit = defineEmits<{
  'update:modelValue': [value: boolean]
}>()
</script>

<template>
  <div
    class="omk-switch-row"
    role="switch"
    :aria-checked="modelValue"
    :aria-disabled="disabled"
    :class="{ 'omk-switch-row--disabled': disabled }"
    @click="!disabled && emit('update:modelValue', !modelValue)"
  >
    <span v-if="$slots.start" class="omk-switch-row__start" aria-hidden="true">
      <slot name="start" />
    </span>
    <span class="omk-switch-row__text">
      <span class="omk-switch-row__title">{{ title }}</span>
      <small v-if="summary" class="omk-switch-row__summary">{{ summary }}</small>
    </span>
    <span
      class="omk-mini-switch"
      :class="{ 'omk-mini-switch--on': modelValue }"
      aria-hidden="true"
    >
      <span class="omk-mini-switch__thumb" />
    </span>
  </div>
</template>
