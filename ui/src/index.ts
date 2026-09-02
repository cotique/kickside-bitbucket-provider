import { WippyVueElement, define } from '@wippy-fe/webcomponent-vue'
import type { WippyElementConfig, WippyPropsSchema } from '@wippy-fe/webcomponent-vue'
import type { ComponentProps } from './types.ts'
import CotiqueBitbucketProviderView from './app/bitbucket-provider.vue'
import stylesText from './styles.css?inline'
import pkg from '../package.json'

class CotiqueBitbucketProviderElement extends WippyVueElement<ComponentProps, Record<string, never>> {
  static get wippyConfig(): WippyElementConfig<ComponentProps> {
    return {
      propsSchema: pkg.wippy.props as WippyPropsSchema,
      hostCssKeys: ['themeConfigUrl'] as const,
      inlineCss: stylesText,
    }
  }

  static get vueConfig() {
    return { rootComponent: CotiqueBitbucketProviderView }
  }
}

export async function webComponent() {
  return CotiqueBitbucketProviderElement
}

define(import.meta.url, CotiqueBitbucketProviderElement)
