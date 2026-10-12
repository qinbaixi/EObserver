// Tree-shaken ECharts setup shared by all charts.
import { use } from 'echarts/core'
import { CanvasRenderer } from 'echarts/renderers'
import { LineChart, HeatmapChart } from 'echarts/charts'
import {
  GridComponent, TooltipComponent, LegendComponent, VisualMapComponent,
} from 'echarts/components'

use([CanvasRenderer, LineChart, HeatmapChart, GridComponent, TooltipComponent,
  LegendComponent, VisualMapComponent])
