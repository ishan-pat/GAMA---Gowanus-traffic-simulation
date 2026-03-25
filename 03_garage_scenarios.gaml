/**
* Model 03 — Garage Parking: Multi-Year Scenarios
* =================================================
* Gowanus Urban Design Strategy Studio
*
* INSIGHT:
*   Gowanus has 2,075 real on-street spots at ~90% midday occupancy today.
*   The 2021 rezoning adds 8,000 new residential units by 2034 — each unit
*   brings more resident vehicles competing for the same street spots as
*   visitors and local businesses.
*
* TRANSFORMATION:
*   2029 — Mixed Garage Policy: new garages open; residents incentivized in
*           via pricing/assignment; visitors keep street spots
*   2034 — Garage Only Policy: street parking fully eliminated; all vehicles
*           must use garages; overflow (no garage space) must leave
*
* PREDICTION (2-axis framework):
*   Axis 1 — Time:         2024 (today) → 2029 (5 yr) → 2034 (10 yr)
*   Axis 2 — Intervention: No Action ↔ Garage Policy
*
* SCENARIOS:
*   2024_baseline      — today, street-only, 90% occ, low demand
*   2029_no_action     — +30% residents, no garages, streets near-full
*   2029_mixed_garages — same demand, garages open for residents
*   2034_no_action     — full buildout, streets overwhelmed, high overflow
*   2034_garage_only   — garage-only policy, streets freed, overflow managed
*/

model garage_parking_scenarios

global {
	float step <- 10 #s;
	float arrival_threshold <- 0.00008;

	// ── GIS Layers ────────────────────────────────────────────────────────────
	file shapefile_roads     <- shape_file("includes/Brooklyn.shp");
	file shapefile_bid       <- shape_file("includes/BID_vector.shp");
	file shapefile_spots     <- shape_file("includes/gowanus_final_spots.shp");
	file shapefile_water     <- shape_file("includes/bid_water.shp");
	file shapefile_buildings <- shape_file("includes/bid_buildings.shp");

	geometry shape    <- envelope(shapefile_roads);
	geometry bid_geom <- nil;
	graph road_network;

	// ── Scenario Selector ─────────────────────────────────────────────────────
	string scenario_name <- "2024_baseline";
	// among: 2024_baseline | 2029_no_action | 2029_mixed_garages
	//        2034_no_action | 2034_garage_only

	// ── Mode (set by scenario) ────────────────────────────────────────────────
	// "street_only"  — no garages used; everyone competes for street spots
	// "mixed"        — residents go to garages; visitors use street spots
	// "garage_only"  — no street spots; everyone must use garages or leave
	string parking_mode <- "street_only";

	// ── Supply (set by scenario) ──────────────────────────────────────────────
	int   garage_capacity_per_facility <- 0;
	float initial_garage_occupied_rate <- 0.0;
	float initial_street_occupied_rate <- 0.90;

	// ── Demand (set by scenario) ──────────────────────────────────────────────
	float resident_share        <- 0.30;
	int   initial_cars          <- 60;
	float spawn_prob_per_step   <- 0.10;
	int   max_new_cars_per_spawn <- 2;
	int   max_search_attempts   <- 8;

	// ── Dwell times (10 s/step) ───────────────────────────────────────────────
	int resident_min_dwell <- 1800;    // ~5 h
	int resident_max_dwell <- 10800;   // ~30 h
	int visitor_min_dwell  <- 180;     // ~30 min
	int visitor_max_dwell  <- 720;     // ~2 h

	// ── Boundary helpers ──────────────────────────────────────────────────────
	list<road> boundary_roads <- [];
	float area_boundary_buffer <- 0.0008;
	float area_min_x <- 0.0; float area_max_x <- 0.0;
	float area_min_y <- 0.0; float area_max_y <- 0.0;

	// ── Metrics ───────────────────────────────────────────────────────────────
	int   residents_parked_garage <- 0;
	int   residents_parked_street <- 0;
	int   visitors_parked_street  <- 0;
	int   overflow_left           <- 0;
	int   total_garage_occupied   <- 0;
	int   total_street_occupied   <- 0;
	float garage_occupancy_pct    <- 0.0;
	float street_occupancy_pct    <- 0.0;

	init {
		do apply_scenario_parameters;

		create bid_boundary from: shapefile_bid;
		if not empty(bid_boundary) { bid_geom <- one_of(bid_boundary).shape; }

		create water_body from: shapefile_water;

		create road from: shapefile_roads with: [
			fclass::string(read("fclass")),
			road_name::string(read("name"))
		];

		list<float> area_xs <- shape.points collect each.x;
		list<float> area_ys <- shape.points collect each.y;
		area_min_x <- min(area_xs); area_max_x <- max(area_xs);
		area_min_y <- min(area_ys); area_max_y <- max(area_ys);

		road_network <- as_edge_graph(road where (each.navigable_for_agents));
		boundary_roads <- road where (each.navigable_for_agents and each.near_area_boundary);
		if empty(boundary_roads) { boundary_roads <- road where (each.navigable_for_agents); }
		if empty(boundary_roads) { boundary_roads <- road where (each.drivable); }

		// Garages — only meaningful when parking_mode != "street_only"
		create garage from: shapefile_buildings with: [btype::string(read("type"))];
		ask garage where (each.btype != "garage" and each.btype != "carport") { do die; }
		ask garage {
			capacity       <- garage_capacity_per_facility;
			occupied_count <- int(garage_capacity_per_facility * initial_garage_occupied_rate);
		}

		// Street spots — not created in garage_only mode
		if parking_mode != "garage_only" {
			create street_spot from: shapefile_spots with: [heading::float(read("heading"))];
			ask street_spot { occupied <- flip(initial_street_occupied_rate); }
		}

		create car number: initial_cars { do init_car; }

		do update_metrics;
	}

	action apply_scenario_parameters {
		// ── 2024 Baseline: street-only, 90% occ, low demand ──
		if scenario_name = "2024_baseline" {
			parking_mode                <- "street_only";
			garage_capacity_per_facility <- 0;
			initial_garage_occupied_rate <- 0.0;
			initial_street_occupied_rate <- 0.90;
			resident_share               <- 0.30;
			initial_cars                 <- 60;
			spawn_prob_per_step          <- 0.10;
			max_new_cars_per_spawn       <- 2;
		}
		// ── 2029 No Action: +30% residents, still street-only, near-full ──
		else if scenario_name = "2029_no_action" {
			parking_mode                <- "street_only";
			garage_capacity_per_facility <- 0;
			initial_garage_occupied_rate <- 0.0;
			initial_street_occupied_rate <- 0.96;
			resident_share               <- 0.50;
			initial_cars                 <- 80;
			spawn_prob_per_step          <- 0.16;
			max_new_cars_per_spawn       <- 3;
		}
		// ── 2029 Mixed Garages: same demand, residents routed to garages ──
		// Street spots freed up; overflow drops significantly
		else if scenario_name = "2029_mixed_garages" {
			parking_mode                <- "mixed";
			garage_capacity_per_facility <- 150;
			initial_garage_occupied_rate <- 0.40;
			initial_street_occupied_rate <- 0.72;
			resident_share               <- 0.50;
			initial_cars                 <- 80;
			spawn_prob_per_step          <- 0.16;
			max_new_cars_per_spawn       <- 3;
		}
		// ── 2034 No Action: full 8,000-unit buildout, streets overwhelmed ──
		else if scenario_name = "2034_no_action" {
			parking_mode                <- "street_only";
			garage_capacity_per_facility <- 0;
			initial_garage_occupied_rate <- 0.0;
			initial_street_occupied_rate <- 0.99;
			resident_share               <- 0.65;
			initial_cars                 <- 120;
			spawn_prob_per_step          <- 0.28;
			max_new_cars_per_spawn       <- 5;
		}
		// ── 2034 Garage Only: street parking eliminated, garages expanded ──
		// Overflow = cars that can't find garage space and must leave
		else if scenario_name = "2034_garage_only" {
			parking_mode                <- "garage_only";
			garage_capacity_per_facility <- 250;
			initial_garage_occupied_rate <- 0.55;
			initial_street_occupied_rate <- 0.0;
			resident_share               <- 0.65;
			initial_cars                 <- 120;
			spawn_prob_per_step          <- 0.28;
			max_new_cars_per_spawn       <- 5;
		}
		else {
			parking_mode                <- "street_only";
			garage_capacity_per_facility <- 0;
			initial_garage_occupied_rate <- 0.0;
			initial_street_occupied_rate <- 0.90;
			resident_share               <- 0.30;
			initial_cars                 <- 60;
			spawn_prob_per_step          <- 0.10;
			max_new_cars_per_spawn       <- 2;
		}
	}

	reflex spawn_arrivals when: flip(spawn_prob_per_step) {
		int n <- 1 + rnd(max_new_cars_per_spawn - 1);
		create car number: n { do init_car; }
	}

	reflex refresh_metrics { do update_metrics; }

	action update_metrics {
		int total_garage_cap <- sum(garage collect each.capacity);
		total_garage_occupied <- sum(garage collect each.occupied_count);
		garage_occupancy_pct  <- total_garage_cap > 0 ?
			100.0 * float(total_garage_occupied) / float(total_garage_cap) : 0.0;

		total_street_occupied <- length(street_spot where (each.occupied));
		int total_street      <- length(street_spot);
		street_occupancy_pct  <- total_street > 0 ?
			100.0 * float(total_street_occupied) / float(total_street) : 0.0;
	}
}

// ── Species ───────────────────────────────────────────────────────────────────

species bid_boundary {
	aspect default { draw shape color: rgb(0,0,0,0) border: #red width: 3; }
}

species water_body {
	aspect default { draw shape color: rgb(70,130,180,140) border: rgb(70,130,180); }
}

species road {
	string fclass    <- "unknown";
	string road_name <- "";

	bool drivable <- (
		(fclass = "primary") or (fclass = "primary_link") or
		(fclass = "secondary") or (fclass = "secondary_link") or
		(fclass = "tertiary") or (fclass = "tertiary_link") or
		(fclass = "residential") or (fclass = "residentioal") or
		(fclass = "service") or (fclass = "unclassified") or
		(fclass = "trunk") or (fclass = "trunk_link") or
		(fclass = "motorway") or (fclass = "motorway_link")
	);

	bool navigable_for_agents <- (
		drivable and
		(fclass != "service") and (fclass != "unclassified") and
		(fclass != "residentioal") and (fclass != "motorway") and
		(fclass != "motorway_link")
	);

	bool in_bid <- ((bid_geom != nil) and (location intersects bid_geom));

	bool near_area_boundary <- (
		(location.x <= (area_min_x + area_boundary_buffer)) or
		(location.x >= (area_max_x - area_boundary_buffer)) or
		(location.y <= (area_min_y + area_boundary_buffer)) or
		(location.y >= (area_max_y - area_boundary_buffer))
	);

	aspect default {
		if in_bid and drivable {
			draw shape color: rgb(80,80,80) width: 2;
		} else if drivable and (fclass = "primary" or fclass = "secondary" or fclass = "trunk") {
			draw shape color: rgb(110,110,110) width: 2;
		} else if drivable {
			draw shape color: rgb(160,160,160) width: 1;
		} else {
			draw shape color: rgb(210,210,210) width: 1;
		}
	}
}

species garage {
	string btype         <- "unknown";
	int    capacity      <- 200;
	int    occupied_count <- 0;
	bool   has_space     <- true update: (occupied_count < capacity);
	float  occupancy_pct <- 0.0  update:
		(100.0 * float(occupied_count) / float(max([1, capacity])));

	action claim_spot   { occupied_count <- min([capacity, occupied_count + 1]); }
	action release_spot { occupied_count <- max([0, occupied_count - 1]); }

	aspect default {
		if capacity = 0 {
			draw shape color: rgb(180,180,180) border: #black;
		} else if occupancy_pct < 60.0 {
			draw shape color: #forestgreen border: #black;
			draw circle(14) color: #forestgreen border: #white;
		} else if occupancy_pct < 85.0 {
			draw shape color: #darkorange border: #black;
			draw circle(14) color: #darkorange border: #white;
		} else {
			draw shape color: #red border: #black;
			draw circle(14) color: #red border: #white;
		}
	}
}

species street_spot {
	float heading  <- 0.0;
	bool  occupied <- false;

	aspect default {
		draw square(8) color: (occupied ? #red : #lime) rotate: heading;
	}
}

species car skills: [moving] {
	string car_type      <- "visitor";
	string state         <- "arriving";
	int    dwell_steps   <- 0;
	int    search_attempts <- 0;
	point  exit_target   <- nil;
	garage      target_garage <- nil;
	street_spot target_spot   <- nil;

	action init_car {
		car_type <- flip(resident_share) ? "resident" : "visitor";
		state    <- "arriving";
		road start_road <- one_of(boundary_roads);
		if start_road = nil { start_road <- one_of(road where (each.navigable_for_agents)); }
		if start_road != nil { location <- any_location_in(start_road); }
		do choose_initial_destination;
	}

	action choose_initial_destination {
		if parking_mode = "garage_only" {
			do seek_garage;
		} else if parking_mode = "mixed" and car_type = "resident" {
			do seek_garage;
		} else {
			do seek_street;
		}
	}

	action seek_garage {
		list<garage> available <- garage where (each.has_space);
		if not empty(available) {
			target_garage <- available with_min_of (each distance_to location);
			state <- "seeking_garage";
			target_spot <- nil;
		} else {
			if parking_mode = "mixed" and car_type = "resident" {
				do seek_street;
			} else {
				overflow_left <- overflow_left + 1;
				do start_leaving;
			}
		}
	}

	action seek_street {
		list<street_spot> free <- street_spot where (not each.occupied);
		if not empty(free) {
			target_spot <- free with_min_of (each distance_to location);
			state <- "seeking_street";
			target_garage <- nil;
		} else {
			overflow_left <- overflow_left + 1;
			do start_leaving;
		}
	}

	action start_leaving {
		state <- "leaving";
		road exit_road <- one_of(boundary_roads);
		if exit_road = nil { exit_road <- one_of(road where (each.navigable_for_agents)); }
		if exit_road != nil { exit_target <- any_location_in(exit_road); }
	}

	reflex drive_to_garage when: state = "seeking_garage" and target_garage != nil {
		speed <- 25 #km/#h;
		do goto target: target_garage.location on: road_network recompute_path: false;
		if (location distance_to target_garage.location) < (arrival_threshold * 20000) {
			if target_garage.has_space {
				ask target_garage { do claim_spot; }
				state <- "parked_garage";
				dwell_steps <- (car_type = "resident") ?
					(resident_min_dwell + rnd(resident_max_dwell - resident_min_dwell)) :
					(visitor_min_dwell  + rnd(visitor_max_dwell  - visitor_min_dwell));
				residents_parked_garage <- residents_parked_garage + 1;
			} else {
				search_attempts <- search_attempts + 1;
				if search_attempts < max_search_attempts {
					do seek_garage;
				} else {
					overflow_left <- overflow_left + 1;
					do start_leaving;
				}
			}
		}
	}

	reflex drive_to_spot when: state = "seeking_street" and target_spot != nil {
		speed <- 20 #km/#h;
		do goto target: target_spot.location on: road_network recompute_path: false;
		if (location distance_to target_spot.location) < (arrival_threshold * 20000) {
			if not target_spot.occupied {
				target_spot.occupied <- true;
				state <- "parked_street";
				dwell_steps <- (car_type = "resident") ?
					(resident_min_dwell + rnd(resident_max_dwell - resident_min_dwell)) :
					(visitor_min_dwell  + rnd(visitor_max_dwell  - visitor_min_dwell));
				if car_type = "resident" {
					residents_parked_street <- residents_parked_street + 1;
				} else {
					visitors_parked_street <- visitors_parked_street + 1;
				}
			} else {
				search_attempts <- search_attempts + 1;
				if search_attempts < max_search_attempts {
					do seek_street;
				} else {
					overflow_left <- overflow_left + 1;
					do start_leaving;
				}
			}
		}
	}

	reflex dwell_in_garage when: state = "parked_garage" {
		dwell_steps <- dwell_steps - 1;
		if dwell_steps <= 0 {
			ask target_garage { do release_spot; }
			target_garage <- nil;
			do start_leaving;
		}
	}

	reflex dwell_on_street when: state = "parked_street" {
		dwell_steps <- dwell_steps - 1;
		if dwell_steps <= 0 {
			if target_spot != nil { target_spot.occupied <- false; }
			target_spot <- nil;
			do start_leaving;
		}
	}

	reflex drive_to_exit when: state = "leaving" and exit_target != nil {
		speed <- 30 #km/#h;
		do goto target: exit_target on: road_network recompute_path: false;
		if (location distance_to exit_target) < (arrival_threshold * 20000) { do die; }
	}

	aspect default {
		if state = "parked_garage" {
			draw circle(6) color: #gold border: #white;
		} else if state = "parked_street" {
			draw circle(6) color: #yellow border: rgb(80,80,0);
		} else if state = "seeking_garage" and car_type = "resident" {
			draw circle(6) color: rgb(0,200,100) border: #white;
		} else if state = "seeking_garage" {
			draw circle(6) color: rgb(0,150,255) border: #white;
		} else if state = "seeking_street" {
			draw circle(6) color: rgb(255,140,0) border: #white;
		} else if state = "leaving" {
			draw circle(5) color: rgb(180,0,200) border: #white;
		} else {
			draw circle(5) color: #white border: rgb(100,100,100);
		}
	}
}

// ── Experiment ────────────────────────────────────────────────────────────────

experiment garage_scenarios type: gui {
	parameter "Scenario" var: scenario_name category: "Scenario"
		among: ["2024_baseline","2029_no_action","2029_mixed_garages",
		        "2034_no_action","2034_garage_only"];

	output {
		monitor "Scenario"                   value: scenario_name;
		monitor "Parking Mode"               value: parking_mode;
		monitor "Active Cars"                value: length(car);
		monitor "Garage Occupancy %"         value: int(garage_occupancy_pct);
		monitor "Street Occupancy %"         value: int(street_occupancy_pct);
		monitor "Residents → Garage"         value: residents_parked_garage;
		monitor "Residents → Street (spill)" value: residents_parked_street;
		monitor "Visitors → Street"          value: visitors_parked_street;
		monitor "Overflow (left w/o parking)" value: overflow_left;

		display "Gowanus — Garage Scenarios" type: 2d background: #white {
			species water_body;
			species road;
			species street_spot;
			species garage;
			species bid_boundary;
			species car;
		}

		display "Prediction Charts" type: 2d {
			chart "Occupancy %" type: series
				size: {1.0, 0.34} position: {0.0, 0.0} {
				data "Garage occupancy %"
					value: garage_occupancy_pct color: #forestgreen style: line;
				data "Street occupancy %"
					value: street_occupancy_pct color: #steelblue style: line;
			}
			chart "Where Residents Park" type: series
				size: {1.0, 0.33} position: {0.0, 0.34} {
				data "Residents in garage"
					value: residents_parked_garage color: #gold style: line;
				data "Residents on street (spill)"
					value: residents_parked_street color: #darkorange style: line;
				data "Visitors on street"
					value: visitors_parked_street color: #steelblue style: line;
			}
			chart "Overflow: Left Without Parking" type: series
				size: {1.0, 0.33} position: {0.0, 0.67} {
				data "Cars left without parking"
					value: overflow_left color: #red style: line;
			}
		}
	}
}
