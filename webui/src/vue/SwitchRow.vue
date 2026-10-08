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
    class="switch-row"
    role="switch"
    :aria-checked="modelValue"
    :aria-disabled="disabled"
    :class="{ 'switch-row--disabled': disabled }"
    @click="!disabled && emit('update:modelValue', !modelValue)"
  >
    <span v-if="$slots.start" class="switch-row__start" aria-hidden="true">
      <slot name="start" />
    </span>
    <span class="switch-row__text">
      <span class="switch-row__title">{{ title }}</span>
      <small v-if="summary" class="switch-row__summary">{{ summary }}</small>
    </span>
    <span
      class="mini-switch"
      :class="{ 'mini-switch--on': modelValue }"
      aria-hidden="true"
    >
      <span class="mini-switch__thumb" />
    </span>
  </div>
</template>

<style scoped>
.switch-row {
  display: flex;
  align-items: center;
  box-sizing: border-box;
  gap: 12px;
  width: 100%;
  min-height: 56px;
  padding: 12px 16px;
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
}

.switch-row--disabled {
  cursor: default;
  opacity: 0.5;
}

.switch-row__start {
  display: inline-flex;
  flex: none;
  align-items: center;
  justify-content: center;
  pointer-events: none;
}

.switch-row__text {
  display: flex;
  flex: 1;
  flex-direction: column;
  gap: 3px;
  min-width: 0;
}

.switch-row__title {
  color: var(--m-color-on-surface);
  font-size: 17px;
  line-height: 1.25;
  overflow-wrap: anywhere;
}

.switch-row__summary {
  color: var(--m-color-on-surface-variant-summary);
  font-size: 13px;
  line-height: 1.4;
  overflow-wrap: anywhere;
}

/* Own switch control: the library switch listens to pointer events only, which
   is unreliable on Android WebView. */
.mini-switch {
  flex: none;
  position: relative;
  display: inline-block;
  box-sizing: border-box;
  width: 42px;
  height: 25px;
  border-radius: 999px;
  background: var(--m-color-secondary, rgba(120, 120, 128, 0.32));
  transition: background-color 160ms ease;
}

.mini-switch--on {
  background: var(--m-color-primary);
}

.mini-switch__thumb {
  position: absolute;
  top: 2px;
  left: 2px;
  box-sizing: border-box;
  width: 21px;
  height: 21px;
  border-radius: 50%;
  background: #fff;
  box-shadow: 0 1px 3px rgb(0 0 0 / 25%);
  transition: transform 160ms ease;
}

.mini-switch--on .mini-switch__thumb {
  transform: translateX(17px);
}
</style>
