extensions [ csv py ]

globals [
  n-nodes
  max-hours
  truck-capacity
  monte-carlo-runs

  initial-demand
  demand-left
  window-start
  window-end
  risk-matrix
  truck-times

  current-time
  current-node
  delivered-demand
  on-time-demand
  late-demand
  unmet-demand
  total-demand
  dispatch-decisions
  routing-decisions
  decision-time-sum
  completion-status
  active-policy
  current-iteration

  results-file
  debug?
]

breed [ locations location ]
locations-own [
  node-id
  original-demand
  remaining-demand
  w-start
  w-end
  is-depot?
]

breed [ trucks truck ]
trucks-own [
  current-node-id
]

to setup
  clear-all

  set n-nodes 18
  set max-hours 480
  set truck-capacity 10
  set monte-carlo-runs 100
  set results-file "results.csv"
  set debug? true

  debug-print "SETUP: Loading data..."
  load-data

  debug-print "SETUP: Starting Python session..."
  setup-python

  debug-print "SETUP: Creating world..."
  setup-world

  debug-print "SETUP COMPLETE."
  reset-ticks
end

to load-data
  set initial-demand load-column "data/initial_demand.csv" n-nodes
  set window-start load-column "data/window_start.csv" n-nodes
  set window-end load-column "data/window_end.csv" n-nodes
  set risk-matrix load-square-matrix "data/risk_matrix.csv" n-nodes
  set truck-times load-square-matrix "data/truck_times.csv" n-nodes

  ;; node 0 is the depot, so demand is forced to 0
  set initial-demand replace-item 0 initial-demand 0

  debug-print (word "DATA LOADED: " n-nodes " nodes.")
  debug-print (word "DATA LOADED: Total demand = " sum initial-demand)
end

to-report load-column [ filename limit-n ]
  debug-print (word "Loading column file: " filename)
  let rows csv:from-file filename
  set rows sublist rows 0 limit-n
  report map [ row -> item 0 row ] rows
end

to-report load-square-matrix [ filename limit-n ]
  debug-print (word "Loading matrix file: " filename)
  let rows csv:from-file filename
  set rows sublist rows 0 limit-n
  report map [ row -> sublist row 0 limit-n ] rows
end

to setup-python
  py:setup py:python
  py:run "import sys, os, json"
  py:run "sys.path.append(os.getcwd())"
  py:run "import ollama_agent"
  py:run "ollama_agent.reset_caches()"

  debug-print "PYTHON READY: ollama_agent.py imported and caches reset."
end

to setup-world
  clear-turtles
  clear-links

  create-locations n-nodes [
    set node-id who
    set is-depot? (node-id = 0)
    set original-demand item node-id initial-demand
    set remaining-demand original-demand
    set w-start item node-id window-start
    set w-end item node-id window-end

    set shape "circle"
    set size ifelse-value is-depot? [2.2] [1.4]
    set color ifelse-value is-depot? [blue] [green]
    set label node-id
  ]

  ;; Create a complete undirected visual network for layout only.
  ask locations [
    let me self
    ask locations with [ self != me and node-id > [node-id] of me ] [
      create-link-with me [
        set color gray + 2
        set thickness 0.05
      ]
    ]
  ]

  layout-circle locations 12

  create-trucks 1 [
    set shape "truck"
    set size 2
    set color red
    set current-node-id 0
    move-to one-of locations with [ node-id = 0 ]
  ]

  debug-print "WORLD READY: Locations, links, and truck created."
end

to reset-iteration [ policy-name iter ]
  set active-policy policy-name
  set current-iteration iter
  set demand-left initial-demand
  set current-time 0
  set current-node 0
  set delivered-demand 0
  set on-time-demand 0
  set late-demand 0
  set unmet-demand 0
  set total-demand sum initial-demand
  set dispatch-decisions 0
  set routing-decisions 0
  set decision-time-sum 0
  set completion-status "running"

  ask locations [
    set remaining-demand item node-id demand-left
    set color ifelse-value is-depot? [blue] [green]
  ]

  ask trucks [
    set current-node-id 0
    move-to one-of locations with [ node-id = 0 ]
  ]

  debug-print "--------------------------------------------------"
  debug-print (word "STARTING ITERATION " current-iteration " | POLICY: " active-policy)
  debug-print (word "Initial total demand: " total-demand)
  debug-print "--------------------------------------------------"

  reset-ticks
end

to run-rule-based
  setup
  initialize-results-file
  reset-iteration "rule-based" 1
  run-current-policy
  export-result-row
end

to run-llm-based
  setup
  initialize-results-file
  reset-iteration "llm-assisted" 1
  run-current-policy
  export-result-row
end

to run-full-monte-carlo
  setup
  initialize-results-file

  let i 1
  while [ i <= monte-carlo-runs ] [
    debug-print (word "MONTE CARLO: Starting run " i " of " monte-carlo-runs " for rule-based policy.")
    random-seed i
    reset-iteration "rule-based" i
    run-current-policy
    export-result-row

    debug-print (word "MONTE CARLO: Starting run " i " of " monte-carlo-runs " for LLM-assisted policy.")
    random-seed i
    reset-iteration "llm-assisted" i
    run-current-policy
    export-result-row

    debug-print (word "MONTE CARLO: Finished pair of runs for iteration " i ".")
    set i i + 1
  ]

  debug-print "FULL MONTE CARLO COMPLETE. Results exported to results.csv."
end

to run-current-policy
  while [ any-demand-left? and current-time < max-hours ] [

    debug-print "--------------------------------------------------"
    debug-print (word "ITERATION: " current-iteration
                  " | POLICY: " active-policy
                  " | TIME: " precision current-time 2
                  " hrs"
                  " | TRUCK AT NODE: " current-node
                  " | REMAINING DEMAND: " sum demand-left)

    debug-print "STEP: Choosing dispatch target..."
    let target choose-dispatch-target

    if target = -1 [
      debug-print "WARNING: No valid target was selected. Stopping this run."
      set completion-status "no-target"
      stop
    ]

    debug-print (word "DISPATCH RESULT: Selected target node " target)

    debug-print (word "STEP: Choosing route from node " current-node " to node " target "...")
    let route-info choose-route target
    let path item 0 route-info
    let base-time item 1 route-info
    let avg-risk item 2 route-info
    let route-decision-time item 3 route-info

    debug-print (word "ROUTE RESULT: Path = " path)
    debug-print (word "ROUTE RESULT: Base travel time = " precision base-time 2 " hrs")
    debug-print (word "ROUTE RESULT: Average risk = " precision avg-risk 2)
    debug-print (word "ROUTE RESULT: Routing decision time = " precision route-decision-time 4 " seconds")

    set decision-time-sum decision-time-sum + route-decision-time

    debug-print "STEP: Sampling uncertainty/disruption..."
    let actual-time sample-trip-time base-time avg-risk

    debug-print (word "TRAVEL RESULT: Actual travel time = " precision actual-time 2 " hrs")
    set current-time current-time + actual-time

    debug-print (word "STEP: Delivering to node " target "...")
    deliver-to target

    set current-node target
    ask trucks [
      set current-node-id target
      move-to one-of locations with [ node-id = target ]
    ]

    update-location-colors

    debug-print (word "STATUS: Delivered demand so far = " delivered-demand)
    debug-print (word "STATUS: On-time demand so far = " on-time-demand)
    debug-print (word "STATUS: Late demand so far = " late-demand)
    debug-print (word "STATUS: Unmet demand currently = " sum demand-left)
    debug-print (word "STATUS: Remaining demand = " sum demand-left)
    debug-print (word "STATUS: Current simulation time = " precision current-time 2 " hrs")

    tick
  ]

  debug-print "FINALIZING: Checking unmet demand and final failures..."
  finalize-failures

  ifelse any-demand-left?
  [ set completion-status "time-limit" ]
  [ set completion-status "all-demand-met" ]

  let total-failed late-demand + unmet-demand
  let service-rate delivered-demand / total-demand
  let on-time-rate on-time-demand / total-demand
  let late-rate late-demand / total-demand
  let unmet-rate unmet-demand / total-demand
  let failure-rate total-failed / total-demand

  debug-print "--------------------------------------------------"
  debug-print (word "RUN COMPLETE | ITERATION: " current-iteration " | POLICY: " active-policy)
  debug-print (word "Completion status: " completion-status)
  debug-print (word "Final time: " precision current-time 2 " hrs")
  debug-print (word "Delivered demand: " delivered-demand)
  debug-print (word "On-time demand: " on-time-demand)
  debug-print (word "Late demand: " late-demand)
  debug-print (word "Unmet demand: " unmet-demand)
  debug-print (word "Total failed demand: " total-failed)
  debug-print (word "Service rate: " precision service-rate 4)
  debug-print (word "On-time rate: " precision on-time-rate 4)
  debug-print (word "Late rate: " precision late-rate 4)
  debug-print (word "Unmet rate: " precision unmet-rate 4)
  debug-print (word "Failure rate: " precision failure-rate 4)
  debug-print (word "Dispatch decisions: " dispatch-decisions)
  debug-print (word "Routing decisions: " routing-decisions)
  debug-print "--------------------------------------------------"
end

to-report any-demand-left?
  report any? locations with [ node-id != 0 and item node-id demand-left > 0 ]
end

to-report choose-dispatch-target
  set dispatch-decisions dispatch-decisions + 1

  if active-policy = "rule-based" [
    debug-print "DISPATCH: Using rule-based nearest-first policy."

    let candidates locations with [ node-id != 0 and item node-id demand-left > 0 ]
    if not any? candidates [ report -1 ]

    let selected min-one-of candidates [
      item node-id (item current-node truck-times)
    ]

    debug-print (word "DISPATCH: Rule-based selected node " [node-id] of selected)
    report [node-id] of selected
  ]

  ;; LLM-assisted dispatch with rounded 10-hour cache block.
  let time-block round (current-time / 10) * 10

  debug-print "DISPATCH: Calling LLM-assisted dispatch..."
  debug-print (word "DISPATCH PROMPT STATE: time block = " time-block
                    ", current node = " current-node
                    ", remaining demand = " sum demand-left)

  py:set "current_time_block" time-block
  py:set "current_node" current-node
  py:set "demand" demand-left
  py:set "window_end" window-end
  py:set "time_matrix" truck-times

  let raw py:runresult "ollama_agent.choose_dispatch_json(current_time_block, current_node, demand, window_end, time_matrix)"

  debug-print (word "DISPATCH: Raw Python/LLM response = " raw)

  let parsed json-to-list raw

  let chosen item 1 item 0 parsed
  let dtime item 1 item 1 parsed

  set decision-time-sum decision-time-sum + dtime

  debug-print (word "DISPATCH: LLM selected node " chosen)
  debug-print (word "DISPATCH: Decision time = " precision dtime 4 " seconds")

  report chosen
end

to-report choose-route [ target ]
  set routing-decisions routing-decisions + 1

  if active-policy = "rule-based" [
    debug-print "ROUTING: Using rule-based shortest-path routing."

    py:set "current" current-node
    py:set "target" target
    py:set "time_matrix" truck-times

    let raw py:runresult "ollama_agent.shortest_path_json(current, target, time_matrix)"

    debug-print (word "ROUTING: Raw Python response = " raw)

    let parsed json-to-list raw

    let path item 1 item 0 parsed
    let base-time item 1 item 1 parsed
    let dtime item 1 item 2 parsed
    let avg-risk average-risk-for-path path

    debug-print (word "ROUTING: Rule-based shortest path = " path)

    report (list path base-time avg-risk dtime)
  ]

  debug-print "ROUTING: Calling LLM-assisted route selector..."
  debug-print (word "ROUTING STATE: current node = " current-node ", target node = " target)

  py:set "current" current-node
  py:set "target" target
  py:set "time_matrix" truck-times
  py:set "risk_matrix" risk-matrix

  let raw py:runresult "ollama_agent.choose_route_json(current, target, time_matrix, risk_matrix)"

  debug-print (word "ROUTING: Raw Python/LLM response = " raw)

  let parsed json-to-list raw

  ;; Expected JSON object order from Python:
  ;; choice, path, base_time, avg_risk, decision_time, cached
  let path item 1 item 1 parsed
  let base-time item 1 item 2 parsed
  let avg-risk item 1 item 3 parsed
  let dtime item 1 item 4 parsed

  debug-print (word "ROUTING: LLM-assisted path = " path)
  debug-print (word "ROUTING: LLM route decision time = " precision dtime 4 " seconds")

  report (list path base-time avg-risk dtime)
end

to-report node-row [ matrix node ]
  report item node matrix
end

to-report average-risk-for-path [ path ]
  if length path < 2 [ report 0 ]

  let total-risk 0
  let edge-count 0
  let i 0

  while [ i < (length path - 1) ] [
    let a item i path
    let b item (i + 1) path
    set total-risk total-risk + item b (item a risk-matrix)
    set edge-count edge-count + 1
    set i i + 1
  ]

  report total-risk / edge-count
end

to-report sample-trip-time [ base-time avg-risk ]
  let disruption-prob avg-risk / 10

  debug-print (word "UNCERTAINTY: Disruption probability = " precision disruption-prob 3)

  ifelse random-float 1 < disruption-prob [
    let multiplier 1 + random-float 4
    debug-print (word "UNCERTAINTY: Disruption occurred. Multiplier = " precision multiplier 2)
    report base-time * multiplier
  ] [
    debug-print "UNCERTAINTY: No disruption occurred."
    report base-time
  ]
end
to deliver-to [ target ]
  let remaining item target demand-left
  let delivered min (list truck-capacity remaining)

  debug-print (word "DELIVERY: Node " target " had remaining demand = " remaining)
  debug-print (word "DELIVERY: Truck delivered = " delivered)

  set delivered-demand delivered-demand + delivered

  ifelse current-time > item target window-end [
    set late-demand late-demand + delivered
    debug-print "DELIVERY WARNING: Arrived after deadline. Counted as late delivery."
  ] [
    set on-time-demand on-time-demand + delivered
    debug-print "DELIVERY: On-time delivery."
  ]

  set demand-left replace-item target demand-left (remaining - delivered)
  ask one-of locations with [ node-id = target ] [
    set remaining-demand item target demand-left
  ]

  debug-print (word "DELIVERY: Node " target " remaining demand after delivery = " item target demand-left)
end

to update-location-colors
  ask locations with [ not is-depot? ] [
    ifelse item node-id demand-left <= 0
    [ set color gray ]
    [
      ifelse current-time > w-end
      [ set color red ]
      [ set color green ]
    ]
  ]
end

to finalize-failures
  set unmet-demand sum demand-left
  debug-print (word "FINALIZE: Unmet demand remaining = " unmet-demand)
end

to initialize-results-file
  file-close-all
  if file-exists? results-file [ file-delete results-file ]
  file-open results-file
  file-print "iteration,policy,total_demand,delivered_demand,on_time_demand,late_demand,unmet_demand,total_failed_demand,service_rate,on_time_rate,late_rate,unmet_rate,failure_rate,final_simulation_time,dispatch_decisions,routing_decisions,avg_decision_time_seconds,completion_status"
  file-close

  debug-print (word "RESULTS: Initialized " results-file)
end

to export-result-row
  let avg-decision-time 0
  let n-decisions dispatch-decisions + routing-decisions
  if n-decisions > 0 [
    set avg-decision-time decision-time-sum / n-decisions
  ]

  let total-failed late-demand + unmet-demand

  let service-rate 0
  let on-time-rate 0
  let late-rate 0
  let unmet-rate 0
  let failure-rate 0

  if total-demand > 0 [
    set service-rate delivered-demand / total-demand
    set on-time-rate on-time-demand / total-demand
    set late-rate late-demand / total-demand
    set unmet-rate unmet-demand / total-demand
    set failure-rate total-failed / total-demand
  ]

  file-open results-file
  file-print (word current-iteration ","
                   active-policy ","
                   total-demand ","
                   delivered-demand ","
                   on-time-demand ","
                   late-demand ","
                   unmet-demand ","
                   total-failed ","
                   service-rate ","
                   on-time-rate ","
                   late-rate ","
                   unmet-rate ","
                   failure-rate ","
                   current-time ","
                   dispatch-decisions ","
                   routing-decisions ","
                   avg-decision-time ","
                   completion-status)
  file-close

  debug-print (word "RESULTS: Exported row for iteration " current-iteration " | policy = " active-policy)
end

;; NetLogo has no built-in JSON parser, so this expects the py extension to
;; return simple JSON objects. This minimal parser works with the Python output
;; shape produced by ollama_agent.py by asking Python to convert JSON into
;; key-value pairs before sending to NetLogo.
to-report json-to-list [ raw-json ]
  py:set "raw_json_for_netlogo" raw-json
  report py:runresult "list(json.loads(raw_json_for_netlogo).items())"
end

to debug-print [ message ]
  if debug? [
    print message
  ]
end
@#$#@#$#@
GRAPHICS-WINDOW
210
10
647
448
-1
-1
13.0
1
10
1
1
1
0
1
1
1
-16
16
-16
16
0
0
1
ticks
30.0

BUTTON
17
29
80
62
setup
setup
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

BUTTON
21
89
129
122
run rule based
run-rule-based
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

BUTTON
27
141
130
174
run llm based
run-llm-based
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

BUTTON
30
201
165
234
run full monte carlo
run-full-monte-carlo
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

@#$#@#$#@
## WHAT IS IT?

(a general understanding of what the model is trying to show or explain)

## HOW IT WORKS

(what rules the agents use to create the overall behavior of the model)

## HOW TO USE IT

(how to use the model, including a description of each of the items in the Interface tab)

## THINGS TO NOTICE

(suggested things for the user to notice while running the model)

## THINGS TO TRY

(suggested things for the user to try to do (move sliders, switches, etc.) with the model)

## EXTENDING THE MODEL

(suggested things to add or change in the Code tab to make the model more complicated, detailed, accurate, etc.)

## NETLOGO FEATURES

(interesting or unusual features of NetLogo that the model uses, particularly in the Code tab; or where workarounds were needed for missing features)

## RELATED MODELS

(models in the NetLogo Models Library and elsewhere which are of related interest)

## CREDITS AND REFERENCES

(a reference to the model's URL on the web if it has one, as well as any other necessary credits, citations, and links)
@#$#@#$#@
default
true
0
Polygon -7500403 true true 150 5 40 250 150 205 260 250

airplane
true
0
Polygon -7500403 true true 150 0 135 15 120 60 120 105 15 165 15 195 120 180 135 240 105 270 120 285 150 270 180 285 210 270 165 240 180 180 285 195 285 165 180 105 180 60 165 15

arrow
true
0
Polygon -7500403 true true 150 0 0 150 105 150 105 293 195 293 195 150 300 150

box
false
0
Polygon -7500403 true true 150 285 285 225 285 75 150 135
Polygon -7500403 true true 150 135 15 75 150 15 285 75
Polygon -7500403 true true 15 75 15 225 150 285 150 135
Line -16777216 false 150 285 150 135
Line -16777216 false 150 135 15 75
Line -16777216 false 150 135 285 75

bug
true
0
Circle -7500403 true true 96 182 108
Circle -7500403 true true 110 127 80
Circle -7500403 true true 110 75 80
Line -7500403 true 150 100 80 30
Line -7500403 true 150 100 220 30

butterfly
true
0
Polygon -7500403 true true 150 165 209 199 225 225 225 255 195 270 165 255 150 240
Polygon -7500403 true true 150 165 89 198 75 225 75 255 105 270 135 255 150 240
Polygon -7500403 true true 139 148 100 105 55 90 25 90 10 105 10 135 25 180 40 195 85 194 139 163
Polygon -7500403 true true 162 150 200 105 245 90 275 90 290 105 290 135 275 180 260 195 215 195 162 165
Polygon -16777216 true false 150 255 135 225 120 150 135 120 150 105 165 120 180 150 165 225
Circle -16777216 true false 135 90 30
Line -16777216 false 150 105 195 60
Line -16777216 false 150 105 105 60

car
false
0
Polygon -7500403 true true 300 180 279 164 261 144 240 135 226 132 213 106 203 84 185 63 159 50 135 50 75 60 0 150 0 165 0 225 300 225 300 180
Circle -16777216 true false 180 180 90
Circle -16777216 true false 30 180 90
Polygon -16777216 true false 162 80 132 78 134 135 209 135 194 105 189 96 180 89
Circle -7500403 true true 47 195 58
Circle -7500403 true true 195 195 58

circle
false
0
Circle -7500403 true true 0 0 300

circle 2
false
0
Circle -7500403 true true 0 0 300
Circle -16777216 true false 30 30 240

cow
false
0
Polygon -7500403 true true 200 193 197 249 179 249 177 196 166 187 140 189 93 191 78 179 72 211 49 209 48 181 37 149 25 120 25 89 45 72 103 84 179 75 198 76 252 64 272 81 293 103 285 121 255 121 242 118 224 167
Polygon -7500403 true true 73 210 86 251 62 249 48 208
Polygon -7500403 true true 25 114 16 195 9 204 23 213 25 200 39 123

cylinder
false
0
Circle -7500403 true true 0 0 300

dot
false
0
Circle -7500403 true true 90 90 120

face happy
false
0
Circle -7500403 true true 8 8 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Polygon -16777216 true false 150 255 90 239 62 213 47 191 67 179 90 203 109 218 150 225 192 218 210 203 227 181 251 194 236 217 212 240

face neutral
false
0
Circle -7500403 true true 8 7 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Rectangle -16777216 true false 60 195 240 225

face sad
false
0
Circle -7500403 true true 8 8 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Polygon -16777216 true false 150 168 90 184 62 210 47 232 67 244 90 220 109 205 150 198 192 205 210 220 227 242 251 229 236 206 212 183

fish
false
0
Polygon -1 true false 44 131 21 87 15 86 0 120 15 150 0 180 13 214 20 212 45 166
Polygon -1 true false 135 195 119 235 95 218 76 210 46 204 60 165
Polygon -1 true false 75 45 83 77 71 103 86 114 166 78 135 60
Polygon -7500403 true true 30 136 151 77 226 81 280 119 292 146 292 160 287 170 270 195 195 210 151 212 30 166
Circle -16777216 true false 215 106 30

flag
false
0
Rectangle -7500403 true true 60 15 75 300
Polygon -7500403 true true 90 150 270 90 90 30
Line -7500403 true 75 135 90 135
Line -7500403 true 75 45 90 45

flower
false
0
Polygon -10899396 true false 135 120 165 165 180 210 180 240 150 300 165 300 195 240 195 195 165 135
Circle -7500403 true true 85 132 38
Circle -7500403 true true 130 147 38
Circle -7500403 true true 192 85 38
Circle -7500403 true true 85 40 38
Circle -7500403 true true 177 40 38
Circle -7500403 true true 177 132 38
Circle -7500403 true true 70 85 38
Circle -7500403 true true 130 25 38
Circle -7500403 true true 96 51 108
Circle -16777216 true false 113 68 74
Polygon -10899396 true false 189 233 219 188 249 173 279 188 234 218
Polygon -10899396 true false 180 255 150 210 105 210 75 240 135 240

house
false
0
Rectangle -7500403 true true 45 120 255 285
Rectangle -16777216 true false 120 210 180 285
Polygon -7500403 true true 15 120 150 15 285 120
Line -16777216 false 30 120 270 120

leaf
false
0
Polygon -7500403 true true 150 210 135 195 120 210 60 210 30 195 60 180 60 165 15 135 30 120 15 105 40 104 45 90 60 90 90 105 105 120 120 120 105 60 120 60 135 30 150 15 165 30 180 60 195 60 180 120 195 120 210 105 240 90 255 90 263 104 285 105 270 120 285 135 240 165 240 180 270 195 240 210 180 210 165 195
Polygon -7500403 true true 135 195 135 240 120 255 105 255 105 285 135 285 165 240 165 195

line
true
0
Line -7500403 true 150 0 150 300

line half
true
0
Line -7500403 true 150 0 150 150

pentagon
false
0
Polygon -7500403 true true 150 15 15 120 60 285 240 285 285 120

person
false
0
Circle -7500403 true true 110 5 80
Polygon -7500403 true true 105 90 120 195 90 285 105 300 135 300 150 225 165 300 195 300 210 285 180 195 195 90
Rectangle -7500403 true true 127 79 172 94
Polygon -7500403 true true 195 90 240 150 225 180 165 105
Polygon -7500403 true true 105 90 60 150 75 180 135 105

plant
false
0
Rectangle -7500403 true true 135 90 165 300
Polygon -7500403 true true 135 255 90 210 45 195 75 255 135 285
Polygon -7500403 true true 165 255 210 210 255 195 225 255 165 285
Polygon -7500403 true true 135 180 90 135 45 120 75 180 135 210
Polygon -7500403 true true 165 180 165 210 225 180 255 120 210 135
Polygon -7500403 true true 135 105 90 60 45 45 75 105 135 135
Polygon -7500403 true true 165 105 165 135 225 105 255 45 210 60
Polygon -7500403 true true 135 90 120 45 150 15 180 45 165 90

sheep
false
15
Circle -1 true true 203 65 88
Circle -1 true true 70 65 162
Circle -1 true true 150 105 120
Polygon -7500403 true false 218 120 240 165 255 165 278 120
Circle -7500403 true false 214 72 67
Rectangle -1 true true 164 223 179 298
Polygon -1 true true 45 285 30 285 30 240 15 195 45 210
Circle -1 true true 3 83 150
Rectangle -1 true true 65 221 80 296
Polygon -1 true true 195 285 210 285 210 240 240 210 195 210
Polygon -7500403 true false 276 85 285 105 302 99 294 83
Polygon -7500403 true false 219 85 210 105 193 99 201 83

square
false
0
Rectangle -7500403 true true 30 30 270 270

square 2
false
0
Rectangle -7500403 true true 30 30 270 270
Rectangle -16777216 true false 60 60 240 240

star
false
0
Polygon -7500403 true true 151 1 185 108 298 108 207 175 242 282 151 216 59 282 94 175 3 108 116 108

target
false
0
Circle -7500403 true true 0 0 300
Circle -16777216 true false 30 30 240
Circle -7500403 true true 60 60 180
Circle -16777216 true false 90 90 120
Circle -7500403 true true 120 120 60

tree
false
0
Circle -7500403 true true 118 3 94
Rectangle -6459832 true false 120 195 180 300
Circle -7500403 true true 65 21 108
Circle -7500403 true true 116 41 127
Circle -7500403 true true 45 90 120
Circle -7500403 true true 104 74 152

triangle
false
0
Polygon -7500403 true true 150 30 15 255 285 255

triangle 2
false
0
Polygon -7500403 true true 150 30 15 255 285 255
Polygon -16777216 true false 151 99 225 223 75 224

truck
false
0
Rectangle -7500403 true true 4 45 195 187
Polygon -7500403 true true 296 193 296 150 259 134 244 104 208 104 207 194
Rectangle -1 true false 195 60 195 105
Polygon -16777216 true false 238 112 252 141 219 141 218 112
Circle -16777216 true false 234 174 42
Rectangle -7500403 true true 181 185 214 194
Circle -16777216 true false 144 174 42
Circle -16777216 true false 24 174 42
Circle -7500403 false true 24 174 42
Circle -7500403 false true 144 174 42
Circle -7500403 false true 234 174 42

turtle
true
0
Polygon -10899396 true false 215 204 240 233 246 254 228 266 215 252 193 210
Polygon -10899396 true false 195 90 225 75 245 75 260 89 269 108 261 124 240 105 225 105 210 105
Polygon -10899396 true false 105 90 75 75 55 75 40 89 31 108 39 124 60 105 75 105 90 105
Polygon -10899396 true false 132 85 134 64 107 51 108 17 150 2 192 18 192 52 169 65 172 87
Polygon -10899396 true false 85 204 60 233 54 254 72 266 85 252 107 210
Polygon -7500403 true true 119 75 179 75 209 101 224 135 220 225 175 261 128 261 81 224 74 135 88 99

wheel
false
0
Circle -7500403 true true 3 3 294
Circle -16777216 true false 30 30 240
Line -7500403 true 150 285 150 15
Line -7500403 true 15 150 285 150
Circle -7500403 true true 120 120 60
Line -7500403 true 216 40 79 269
Line -7500403 true 40 84 269 221
Line -7500403 true 40 216 269 79
Line -7500403 true 84 40 221 269

wolf
false
0
Polygon -16777216 true false 253 133 245 131 245 133
Polygon -7500403 true true 2 194 13 197 30 191 38 193 38 205 20 226 20 257 27 265 38 266 40 260 31 253 31 230 60 206 68 198 75 209 66 228 65 243 82 261 84 268 100 267 103 261 77 239 79 231 100 207 98 196 119 201 143 202 160 195 166 210 172 213 173 238 167 251 160 248 154 265 169 264 178 247 186 240 198 260 200 271 217 271 219 262 207 258 195 230 192 198 210 184 227 164 242 144 259 145 284 151 277 141 293 140 299 134 297 127 273 119 270 105
Polygon -7500403 true true -1 195 14 180 36 166 40 153 53 140 82 131 134 133 159 126 188 115 227 108 236 102 238 98 268 86 269 92 281 87 269 103 269 113

x
false
0
Polygon -7500403 true true 270 75 225 30 30 225 75 270
Polygon -7500403 true true 30 75 75 30 270 225 225 270
@#$#@#$#@
NetLogo 6.4.0
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
default
0.0
-0.2 0 0.0 1.0
0.0 1 1.0 0.0
0.2 0 0.0 1.0
link direction
true
0
Line -7500403 true 150 150 90 180
Line -7500403 true 150 150 210 180
@#$#@#$#@
0
@#$#@#$#@
