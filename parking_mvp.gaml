/**
* Name: parking_mvp_bid_context
*
* Purpose
* -------
* Simulate parking pressure inside the BID while displaying a larger surrounding
* Brooklyn road network.
*
* Core decisions
* --------------
* 1) surrounding_roads.shp is used for the full movement network.
* 2) BID_vector.shp defines the actual simulation boundary of interest.
* 3) Parking supply exists only inside the BID.
* 4) Cars may travel on surrounding roads, but are only drawn when inside the BID.
* 5) Cars disappear as soon as they exit the BID in the exiting state.
* 6) Scenario parameters are calibrated to the parking study:
*    - existing_midday: ~94% occupied
*    - no_action_midday: ~106% of capacity, deficit 646
*    - with_action_midday: ~129% of capacity, deficit 2,980
*
* Important limitation
* --------------------
* This model uses a scaled, proxy parking supply inside the BID rather than the
* literal study-area curb count. The key calibration is the occupancy/deficit ratio,
* not the exact absolute number of spaces. Replace the proxy parking generator with
* a real bid_parking_points.shp later for higher fidelity.
*/

model parking_mvp_bid_context

global {
	float step <- 10#s;

	// =========================
	// GIS layers
	// =========================
	file shapefile_bid <- shape_file("../includes/BID_vector.shp");
	file shapefile_buildings <- shape_file("../includes/bid_buildings.shp");
	file shapefile_water <- shape_file("../includes/bid_water.shp");
	file shapefile_surrounding_roads <- shape_file("../includes/bid_roads.shp");

	// world extent = surrounding context
	geometry shape <- envelope(shapefile_surrounding_roads);

	// BID geometry
	geometry bid_geom;

	// network
	graph road_network;
	map<road, float> move_weights;

	// =========================
	// Scenario selector
	// existing_midday | no_action_midday | with_action_midday
	// =========================
	string scenario_name <- "existing_midday";

	// =========================
	// Supply parameters
	// =========================
	int proxy_base_parking_spaces <- 220;
	int nb_parking_spaces <- 220;
	float supply_ratio <- 1.0;

	// =========================
	// Scenario-calibrated pressure
	// =========================
	float initial_occupied_rate <- 0.94;
	float deficit_ratio <- 0.0;

	int initial_searching_cars <- 6;
	float arrival_prob_per_step <- 0.10;
	int max_arrivals_per_event <- 2;

	// =========================
	// Behavior
	// =========================
	float arrival_threshold <- 15.0;
	float entry_exit_buffer <- 1000.0;

	int min_dwell_steps <- 60;          // 10 minutes
	int max_dwell_steps <- 180;         // 30 minutes
	float leave_prob_per_step <- 0.010;

	int exit_duration_steps <- 30;      // 5 minutes
	int max_search_steps <- 240;        // 40 minutes
	float give_up_prob_per_step <- 0.002;

	// =========================
	// Metrics
	// =========================
	int occupied_spaces_count <- 0;
	float occupied_spaces_ratio <- 0.0;

	int entered_bid_count <- 0;
	int left_without_parking_count <- 0;
	int left_after_parking_count <- 0;

	int failed_search_count <- 0;
	int successful_parks_count <- 0;
	int exited_count <- 0;

	float mean_last_search_steps <- 0.0;
	float mean_total_search_steps <- 0.0;
	float mean_current_searching_steps <- 0.0;

	init {
		do apply_scenario_parameters;

		create bid_boundary from: shapefile_bid;
		bid_geom <- one_of(bid_boundary).shape;

		create water_body from: shapefile_water;

		create building from: shapefile_buildings with: [
			type::string(read("type"))
		];

		create road from: shapefile_surrounding_roads with: [
			fclass::string(read("fclass"))
		];

		road_network <- as_edge_graph(road where (each.drivable));
		move_weights <- (road where (each.drivable)) as_map (each::(each.shape.perimeter / each.speed_rate));

		// Proxy parking supply only inside the BID on parking-eligible roads.
		create parking_space number: nb_parking_spaces {
			road r <- one_of(road where (each.parking_candidate));
			if r != nil {
				host_road <- r;
				location <- any_location_in(r);
			}
		}

		// Seed parked cars according to study-based occupied share.
		int initial_parked_cars <- min([length(parking_space), int(length(parking_space) * initial_occupied_rate)]);

		create car number: initial_parked_cars {
			parking_space s <- one_of(parking_space where (not each.occupied));
			if s != nil {
				location <- s.location;
				assigned_spot <- s;
				state <- "parked";
				ever_parked <- true;
				has_been_in_bid <- true;
				inside_bid_prev <- true;
				dwell_steps <- min_dwell_steps + int(rnd(max_dwell_steps - min_dwell_steps + 1));

				s.occupied <- true;
				s.occupant_id <- index;
			}
		}

		// Seed active searchers / queue according to pressure scenario.
		create car number: initial_searching_cars {
			road r <- one_of(road where (each.entry_candidate));
			if r != nil {
				location <- any_location_in(r);
				state <- "searching";
				inside_bid_prev <- false;
				has_been_in_bid <- false;
			}
		}

		do update_metrics;
	}

	action apply_scenario_parameters {
		/*
		Calibration basis from the uploaded parking study:

		Existing midday:
		- 10,415 legal curbside spaces
		- 9,749 occupied
		- 666 available
		- ~94% utilization

		No Action midday:
		- 10,389 capacity
		- 11,035 demand
		- 106% utilization
		- deficit 646

		With Action midday:
		- 10,389 capacity
		- 13,369 demand
		- 129% utilization
		- deficit 2,980

		In this BID model, these are converted into:
		- initial occupied share
		- scaled deficit ratio
		- arrival pressure
		*/

		if scenario_name = "existing_midday" {
			supply_ratio <- 1.0;
			initial_occupied_rate <- 0.936;          // 9749 / 10415
			deficit_ratio <- 0.0;                   // existing has surplus, not deficit
			arrival_prob_per_step <- 0.10;
			max_arrivals_per_event <- 2;
			leave_prob_per_step <- 0.010;
		} else if scenario_name = "no_action_midday" {
			supply_ratio <- 10389.0 / 10415.0;
			initial_occupied_rate <- 0.985;
			deficit_ratio <- 646.0 / 10389.0;
			arrival_prob_per_step <- 0.18;
			max_arrivals_per_event <- 3;
			leave_prob_per_step <- 0.008;
		} else if scenario_name = "with_action_midday" {
			supply_ratio <- 10389.0 / 10415.0;
			initial_occupied_rate <- 0.995;
			deficit_ratio <- 2980.0 / 10389.0;
			arrival_prob_per_step <- 0.32;
			max_arrivals_per_event <- 5;
			leave_prob_per_step <- 0.006;
		} else {
			supply_ratio <- 1.0;
			initial_occupied_rate <- 0.936;
			deficit_ratio <- 0.0;
			arrival_prob_per_step <- 0.10;
			max_arrivals_per_event <- 2;
			leave_prob_per_step <- 0.010;
		}

		nb_parking_spaces <- max([1, int(proxy_base_parking_spaces * supply_ratio)]);

		// Scale the study deficit to the modeled parking supply.
		if deficit_ratio <= 0.0 {
			initial_searching_cars <- 6;
		} else {
			initial_searching_cars <- max([6, int(nb_parking_spaces * deficit_ratio)]);
		}
	}

	reflex update_weights {
		move_weights <- (road where (each.drivable)) as_map (each::(each.shape.perimeter / each.speed_rate));
	}

	// Probabilistic arrivals from outside the BID.
	reflex spawn_arrivals when: flip(arrival_prob_per_step) {
		int new_arrivals <- 1 + int(rnd(max_arrivals_per_event));

		create car number: new_arrivals {
			road r <- one_of(road where (each.entry_candidate));
			if r != nil {
				location <- any_location_in(r);
				state <- "searching";
				inside_bid_prev <- false;
				has_been_in_bid <- false;
			}
		}
	}

	action update_metrics {
		list<car> parked_once <- car where (each.ever_parked);
		list<car> searching_now <- car where (each.state = "searching");

		occupied_spaces_count <- length(parking_space where (each.occupied));
		occupied_spaces_ratio <- occupied_spaces_count / max([1.0, float(length(parking_space))]);

		successful_parks_count <- length(car where (each.ever_parked));

		if empty(parked_once) {
			mean_last_search_steps <- 0.0;
			mean_total_search_steps <- 0.0;
		} else {
			mean_last_search_steps <- mean(parked_once collect each.last_search_steps);
			mean_total_search_steps <- mean(parked_once collect each.total_search_steps);
		}

		if empty(searching_now) {
			mean_current_searching_steps <- 0.0;
		} else {
			mean_current_searching_steps <- mean(searching_now collect each.search_steps_current);
		}
	}

	reflex refresh_metrics {
		do update_metrics;
	}
}

species bid_boundary {
	aspect default {
		draw shape color: rgb(255,255,255) border: #red;
	}
}

species water_body {
	aspect default {
		draw shape color: rgb(120,190,255) border: rgb(80,140,220);
	}
}

species building {
	string type <- "unknown";

	aspect default {
		rgb c <- rgb(180,180,180);
		if type = "garage" {
			c <- rgb(0,180,110);
		}
		draw shape color: c border: rgb(120,120,120);
	}
}


species road {
	string fclass <- "unknown";

	bool drivable <- (
		(fclass = "primary") or
		(fclass = "secondary") or
		(fclass = "tertiary") or
		(fclass = "residential") or
		(fclass = "residentioal") or
		(fclass = "service")
	);

	bool in_bid <- (shape intersects bid_geom);

	bool parking_candidate <- (
		in_bid and
		(
			(fclass = "secondary") or
			(fclass = "tertiary") or
			(fclass = "residential") or
			(fclass = "residentioal") or
			(fclass = "service")
		)
	);

	bool entry_candidate <- (
		drivable and
		(not in_bid) and
		((shape distance_to bid_geom) < entry_exit_buffer)
	);

	bool exit_candidate <- entry_candidate;

	float capacity <- max([1.0, shape.perimeter / 25.0]);

	int nb_cars_here <- 0 update:
		length(car where (
			((each.state = "searching") or (each.state = "exiting")) and
			((each distance_to self) < 8)
		));

	float speed_rate <- 1.0 update:
		max([0.2, exp(- nb_cars_here / capacity)]);

	aspect default {
		if drivable {
			draw shape color: rgb(75,75,75);
		} else {
			draw shape color: rgb(185,185,185);
		}
	}
}

species parking_space {
	road host_road <- nil;
	bool occupied <- false;
	int occupant_id <- -1;

	aspect default {
		draw circle(4) color: (occupied ? #red : #green);
	}
}

species car skills: [moving] {
	parking_space assigned_spot <- nil;
	point exit_target <- nil;

	// searching | parked | exiting
	string state <- "searching";

	int dwell_steps <- 0;
	int exit_timer <- 0;

	int search_steps_current <- 0;
	int last_search_steps <- 0;
	int total_search_steps <- 0;

	bool ever_parked <- false;
	bool has_been_in_bid <- false;
	bool inside_bid_prev <- false;

	float speed <- 15 #km/#h;
	float searching_speed <- 15 #km/#h;
	float exiting_speed <- 25 #km/#h;

	aspect default {
		if (location intersects bid_geom) {
			if state = "parked" {
				draw square(5) color: #black;
			} else if state = "exiting" {
				draw square(5) color: #purple;
			} else {
				draw square(5) color: #blue;
			}
		}
	}

	// Count entry into BID and detect exit from BID.
	reflex track_bid_crossing {
		bool now_inside <- (location intersects bid_geom);

		if ((not inside_bid_prev) and now_inside) {
			entered_bid_count <- entered_bid_count + 1;
			has_been_in_bid <- true;
		}

		if (inside_bid_prev and (not now_inside) and (state = "exiting")) {
			do finalize_exit;
		}

		inside_bid_prev <- now_inside;
	}

	reflex count_search_time when: (state = "searching") {
		search_steps_current <- search_steps_current + 1;
	}

	// Grab a free space inside the BID.
	reflex choose_parking when: ((state = "searching") and (assigned_spot = nil)) {
		list<parking_space> free_spots <- parking_space where (not each.occupied);

		if not empty(free_spots) {
			assigned_spot <- one_of(free_spots);
			assigned_spot.occupied <- true;
			assigned_spot.occupant_id <- index;
		}
	}

	// Searchers can give up if they search too long.
	reflex give_up_search when: (state = "searching") {
		if (search_steps_current >= max_search_steps) or flip(give_up_prob_per_step) {
			if assigned_spot != nil {
				assigned_spot.occupied <- false;
				assigned_spot.occupant_id <- -1;
				assigned_spot <- nil;
			}
			failed_search_count <- failed_search_count + 1;
			do start_exit;
		}
	}

	reflex move_to_parking when: ((state = "searching") and (assigned_spot != nil)) {
		speed <- searching_speed;
		do goto target: assigned_spot.location on: road_network move_weights: move_weights;

		if ((location distance_to assigned_spot.location) < arrival_threshold) {
			state <- "parked";
			dwell_steps <- min_dwell_steps + int(rnd(max_dwell_steps - min_dwell_steps + 1));

			last_search_steps <- search_steps_current;
			total_search_steps <- total_search_steps + search_steps_current;
			search_steps_current <- 0;
			ever_parked <- true;
		}
	}

	// Parked cars leave stochastically or at max dwell time.
	reflex stay_parked when: (state = "parked") {
		dwell_steps <- dwell_steps - 1;

		if flip(leave_prob_per_step) or (dwell_steps <= 0) {
			if assigned_spot != nil {
				assigned_spot.occupied <- false;
				assigned_spot.occupant_id <- -1;
				assigned_spot <- nil;
			}
			do start_exit;
		}
	}

	action start_exit {
		state <- "exiting";
		exit_timer <- exit_duration_steps;

		list<road> exit_roads <- road where (each.exit_candidate);
		if not empty(exit_roads) {
			exit_target <- any_location_in(one_of(exit_roads));
		}
	}

	reflex move_to_exit when: ((state = "exiting") and (exit_target != nil)) {
		speed <- exiting_speed;
		do goto target: exit_target on: road_network move_weights: move_weights;

		exit_timer <- exit_timer - 1;

		if exit_timer <= 0 {
			do finalize_exit;
		}
	}

	action finalize_exit {
		if has_been_in_bid {
			if ever_parked {
				left_after_parking_count <- left_after_parking_count + 1;
			} else {
				left_without_parking_count <- left_without_parking_count + 1;
			}
		}
		exited_count <- exited_count + 1;
		do die;
	}
}

experiment traffic type: gui {
	parameter "Scenario name" var: scenario_name category: "Scenario";
	parameter "Proxy parking spaces" var: proxy_base_parking_spaces category: "Supply";
	parameter "Arrival probability per step" var: arrival_prob_per_step category: "Demand";
	parameter "Max arrivals per event" var: max_arrivals_per_event category: "Demand";
	parameter "Min dwell steps" var: min_dwell_steps category: "Behavior";
	parameter "Max dwell steps" var: max_dwell_steps category: "Behavior";
	parameter "Leave probability per step" var: leave_prob_per_step category: "Behavior";
	parameter "Give-up probability per step" var: give_up_prob_per_step category: "Behavior";

	output {
		monitor "Scenario" value: scenario_name;
		monitor "Occupied parking spaces" value: occupied_spaces_count;
		monitor "Occupied parking ratio" value: occupied_spaces_ratio;
		monitor "Cars searching in model" value: length(car where (each.state = "searching"));
		monitor "Cars parked in BID" value: length(car where (each.state = "parked"));
		monitor "Cars exiting" value: length(car where (each.state = "exiting"));
		monitor "Cars entered BID" value: entered_bid_count;
		monitor "Cars left without parking" value: left_without_parking_count;
		monitor "Cars left after parking" value: left_after_parking_count;
		monitor "Failed searches" value: failed_search_count;
		monitor "Cars exited model" value: exited_count;
		monitor "Mean last search steps" value: mean_last_search_steps;
		monitor "Mean cumulative search steps" value: mean_total_search_steps;
		monitor "Mean current searching steps" value: mean_current_searching_steps;

		display map type: 2d {
			species bid_boundary;
			species water_body;
			species building;
			species road;
			species parking_space;
			species car;
		}
	}
}