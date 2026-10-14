// Tree-shaken ECharts setup shared by all charts.
import { use } from 'echarts/core'
import { CanvasRenderer } from 'echarts/renderers'
import { LineChart, BarChart, HeatmapChart, TreeChart, GraphChart } from 'echarts/charts'
import {
  GridComponent, TooltipComponent, LegendComponent, VisualMapComponent,
} from 'echarts/components'

use([CanvasRenderer, LineChart, BarChart, HeatmapChart, TreeChart, GraphChart, GridComponent, TooltipComponent,
  LegendComponent, VisualMapComponent])
