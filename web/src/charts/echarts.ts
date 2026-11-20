// Tree-shaken ECharts setup shared by all charts.
import { use } from 'echarts/core'
import { CanvasRenderer } from 'echarts/renderers'
import { LineChart, BarChart, HeatmapChart, TreeChart, GraphChart, PieChart } from 'echarts/charts'
import {
  GridComponent, TooltipComponent, LegendComponent, VisualMapComponent, MarkLineComponent, TitleComponent,
} from 'echarts/components'

use([CanvasRenderer, LineChart, BarChart, HeatmapChart, TreeChart, GraphChart, PieChart, GridComponent,
  TooltipComponent, LegendComponent, VisualMapComponent, MarkLineComponent, TitleComponent])

const HTML_ESC: Record<string, string> = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
  "'": '&#39;',
}

export function escapeHtml(v: unknown): string {
  return String(v ?? '').replace(/[&<>"']/g, (c) => HTML_ESC[c]!)
}
