#!/usr/bin/env python3
"""Generate Sudobility logo as SVG."""
import math

SIZE = 1024
CENTER = SIZE // 2

C_BLUE   = (59, 130, 246)
C_INDIGO = (99, 102, 241)
C_VIOLET = (139, 92, 246)
C_PURPLE = (168, 85, 247)
C_CYAN   = (6, 182, 212)

def lerp(c1, c2, t):
    return tuple(int(c1[i] + (c2[i] - c1[i]) * max(0, min(1, t))) for i in range(3))

def multi_gradient(t, stops):
    if t <= stops[0][0]: return stops[0][1]
    if t >= stops[-1][0]: return stops[-1][1]
    for i in range(len(stops) - 1):
        if stops[i][0] <= t <= stops[i+1][0]:
            local_t = (t - stops[i][0]) / (stops[i+1][0] - stops[i][0])
            return lerp(stops[i][1], stops[i+1][1], local_t)
    return stops[-1][1]

s_cells = [
    (1,0),(2,0),(3,0),
    (0,1),(1,1),
    (1,2),(2,2),(3,2),
    (3,3),(4,3),
    (1,4),(2,4),(3,4),
]

cell_size = 120
gap = 16
total_grid = 5 * cell_size + 4 * gap
grid_x0 = CENTER - total_grid // 2
grid_y0 = CENTER - total_grid // 2
radius = 22

stops = [(0.0,C_BLUE),(0.25,C_INDIGO),(0.5,C_VIOLET),(0.75,C_PURPLE),(1.0,C_CYAN)]
y_min = min(r for _,r in s_cells)
y_max = max(r for _,r in s_cells)

lines = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {SIZE} {SIZE}" width="{SIZE}" height="{SIZE}">']

for col, row in s_cells:
    x = grid_x0 + col * (cell_size + gap)
    y = grid_y0 + row * (cell_size + gap)
    t = (row - y_min) / max(y_max - y_min, 1)
    color = multi_gradient(t, stops)
    opacity = (230 + int(25 * (0.5 + 0.5 * math.sin(col * 0.7 + row * 1.3)))) / 255.0
    opacity = min(opacity, 1.0)
    r, g, b = color
    lines.append(f'  <rect x="{x}" y="{y}" width="{cell_size}" height="{cell_size}" rx="{radius}" ry="{radius}" fill="rgb({r},{g},{b})" fill-opacity="{opacity:.3f}"/>')

lines.append('</svg>')

with open('/Users/johnhuang/sudobility/public/logo.svg', 'w') as f:
    f.write('\n'.join(lines) + '\n')

print("SVG saved to public/logo.svg")
