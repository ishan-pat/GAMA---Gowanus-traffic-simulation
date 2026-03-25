/**
* Model 03 — Garage Parking Scenarios
* =====================================
* Gowanus Urban Design Strategy Studio
*
* INSIGHT:
*   Gowanus has 2,075 real on-street parking spots (gowanus_final_spots.shp)
*   and only a handful of existing garage/carport facilities. The 2021 rezoning
*   proposes large structured garages to absorb residential parking demand and
*   free the streetscape for pedestrians and cyclists.
*
* TRANSFORMATION:
*   Policy A — Mixed Use:
*     Residents (new units) are incentivized to park in garages via pricing or
*     assignment. Visitors and through-traffic continue to use on-street spots.
*   Policy B — Garage Only:
*     On-street parking is eliminated. All vehicles must use garages. If garages
*     are full, incoming cars have no option and must leave the area.
*
* PREDICTION (2-axis framework):
*   Axis 1 — Parking policy:   Mixed (garage + street) ↔ Garage-only
*   Axis 2 — Car type:         Resident ↔ Visitor
*
*   Key questions:
*   - How quickly do garages fill under residential demand?
*   - How many visitors get displaced when street parking is removed?
*   - What is the overflow rate (cars that leave without parking)?
*
* DATA:
*   Road network:    Brooklyn.shp  (full Brooklyn OSM roads — colleague contribution)
*   Parking spots:   gowanus_final_spots.shp  (2,075 real spots — colleague contribution)
*   Garage buildings: bid_buildings.shp filtered to type=garage/carport
*/

model garage_parking_scenarios

global {
	float step <- 10 #s;
	float arrival_threshold <- 0.00008;

	// ── GIS Layers ─────────────────────────────────────────────────────────────
	file shapefile_roads     <- shape_file("../includes/Brooklyn.shp");
	file shapefile_bid       <- shape_file("../includes/BID_vector.shp");
	file shapefile_spots     <- shape_file("../includes/gowanus_final_spots.shp");
	file shapefile_water     <- shape_file("../includes/bid_water.shp");
	file shapefile_buildings <- shape_file("../includes/bid_buildings.shp");

	geometry shape   <- envelope(shapefile_roads);
	geometry bid_geom <- nil;

	graph road_network;

	// ── Scenario ────────────────────────────────────────────────────────────────
	// "mixed"       : residents → garages first; visitors → street only
	// "garage_only" : all cars → garages only; street parking eliminated
	string parking_mode <- "mixed";

	// ── Supply ──────────────────────────────────────────────────────────────────
	// Capacity assigned to each garage/carport building
	// (represents the planned large-scale structured garage at that site)
	int garage_capacity_per_facility <- 200;
	// Initial occupancy of garages at simulation start
	float initial_garage_occupied_rate <- 0.50;
	// Initial occupancy of street spots (from parking study: ~90% midday)
	float initial_street_occupied_rate <- 0.90;

	// ── Demand ──────────────────────────────────────────────────────────────────
	// Fraction of incoming cars that are residents (prefer garages)
	float resident_share <- 0.40;
	int   initial_cars          <- 80;
	float spawn_prob_per_step   <- 0.15;
	int   max_new_cars_per_spawn <- 3;
	// Max times a car will retry finding a spot before giving up
	int   max_search_attempts   <- 8;

	// ── Dwell times (step = 10 s) ────────────────────────────────────────────────
	// Residents park long (overnight / all day)
	int resident_min_dwell  <- 1800;   // ~5 hours
	int resident_max_dwell  <- 10800;  // ~30 hours
	// Visitors park short (errand / meal)
	int visitor_min_dwell   <- 180;    // ~30 min
	int visitor_max_dwell   <- 720;    // ~2 hours

	// ── Boundary helpers ─────────────────────────────────────────────────────────
	list<road> boundary_roads <- [];
	float area_boundary_buffer <- 0.0008;
	float area_min_x <- 0.0; float area_max_x <- 0.0;
	float area_min_y <- 0.0; float area_max_y <- 0.0;

	// ── Metrics ──────────────────────────────────────────────────────────────────
	int residents_parked_garage  <- 0;
	int residents_parked_street  <- 0;
	int visitors_parked_street   <- 0;
	int overflow_left            <- 0;   // cars that couldn't park and left
	int total_garage_occupied    <- 0;
	int total_street_occupied    <- 0;
	float garage_occupancy_pct   <- 0.0;
	float street_occupancy_pct   <- 0.0;

	init {
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

		// Load garages from buildings — create all, remove non-garage types
		create garage from: shapefile_buildings with: [btype::string(read("type"))];
		ask garage where (each.btype != "garage" and each.btype != "carport") { do die; }
		ask garage {
			capacity       <- garage_capacity_per_facility;
			occupied_count <- int(garage_capacity_per_facility * initial_garage_occupied_rate);
		}

		// Street spots: only created in mixed mode
		if parking_mode = "mixed" {
			create street_spot from: shapefile_spots with: [
				heading::float(read("heading"))
			];
			ask street_spot { occupied <- flip(initial_street_occupied_rate); }
		}

		// Seed initial cars
		create car number: initial_cars {
			do init_car;
		}

		do update_metrics;
	}

	reflex spawn_arrivals when: flip(spawn_prob_per_step) {
		int n <- 1 + rnd(max_new_cars_per_spawn - 1);
		create car number: n { do init_car; }
	}

	reflex refresh_metrics { do update_metrics; }

	action update_metrics {
		total_garage_occupied <- sum(garage collect each.occupied_count);
		int total_garage_cap  <- sum(garage collect each.capacity);
		garage_occupancy_pct  <- total_garage_cap > 0 ?
			100.0 * float(total_garage_occupied) / float(total_garage_cap) : 0.0;

		if parking_mode = "mixed" {
			total_street_occupied <- length(street_spot where (each.occupied));
			int total_street      <- length(street_spot);
			street_occupancy_pct  <- total_street > 0 ?
				100.0 * float(total_street_occupied) / float(total_street) : 0.0;
		} else {
			total_street_occupied <- 0;
			street_occupancy_pct  <- 0.0;
		}
	}
}

// ── Species ──────────────────────────────────────────────────────────────────

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
	string btype        <- "unknown";
	int   capacity      <- 200;
	int   occupied_count <- 0;
	bool  has_space     <- true update: (occupied_count < capacity);
	float occupancy_pct <- 0.0  update: (100.0 * float(occupied_count) / float(max([1, capacity])));

	action claim_spot   { occupied_count <- min([capacity, occupied_count + 1]); }
	action release_spot { occupied_count <- max([0, occupied_count - 1]); }

	aspect default {
		if occupancy_pct < 60.0 {
			draw shape color: #forestgreen border: #black;
			draw circle(12) color: #forestgreen border: #white;
		} else if occupancy_pct < 85.0 {
			draw shape color: #darkorange border: #black;
			draw circle(12) color: #darkorange border: #white;
		} else {
			draw shape color: #red border: #black;
			draw circle(12) color: #red border: #white;
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
	string car_type   <- "visitor";   // "resident" | "visitor"
	string state      <- "arriving";  // arriving | seeking_garage | seeking_street | parked_garage | parked_street | leaving
	int    dwell_steps <- 0;
	int    search_attempts <- 0;
	point  exit_target <- nil;
	garage    target_garage <- nil;
	street_spot target_spot <- nil;

	action init_car {
		car_type <- flip(resident_share) ? "resident" : "visitor";
		state    <- "arriving";

		road start_road <- one_of(boundary_roads);
		if start_road = nil { start_road <- one_of(road where (each.navigable_for_agents)); }
		if start_road != nil { location <- any_location_in(start_road); }

		do choose_initial_destination;
	}

	action choose_initial_destination {
		// Residents try garage first (both modes)
		// Visitors try street in mixed mode, garage in garage_only mode
		if car_type = "resident" {
			do seek_garage;
		} else if parking_mode = "garage_only" {
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
			// No garage space
			if car_type = "resident" and parking_mode = "mixed" {
				// Residents fall back to street in mixed mode
				do seek_street;
			} else {
				// Garage-only: must leave; visitors in mixed mode don't use garages
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
			// No street spots available
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

	// ── Movement ────────────────────────────────────────────────────────────────

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
				if car_type = "resident" {
					residents_parked_garage <- residents_parked_garage + 1;
				}
			} else {
				// Spot taken since we started driving — try again or give up
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
		if (location distance_to exit_target) < (arrival_threshold * 20000) {
			do die;
		}
	}

	aspect default {
		if state = "parked_garage" {
			draw circle(6) color: #gold border: #white;
		} else if state = "parked_street" {
			draw circle(6) color: #yellow border: rgb(80,80,0);
		} else if state = "seeking_garage" {
			rgb c <- (car_type = "resident") ? rgb(0,200,100) : rgb(0,150,255);
			draw circle(6) color: c border: #white;
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
	parameter "Parking Mode"
		var: parking_mode category: "Scenario"
		among: ["mixed", "garage_only"];
	parameter "Resident Share (%)"
		var: resident_share category: "Demand"
		min: 0.0 max: 1.0;
	parameter "Garage Capacity (per facility)"
		var: garage_capacity_per_facility category: "Supply";
	parameter "Initial Garage Occupancy"
		var: initial_garage_occupied_rate category: "Supply"
		min: 0.0 max: 1.0;
	parameter "Initial Street Occupancy"
		var: initial_street_occupied_rate category: "Supply"
		min: 0.0 max: 1.0;
	parameter "Spawn prob / step"
		var: spawn_prob_per_step category: "Demand";

	output {
		monitor "Mode"                      value: parking_mode;
		monitor "Active Cars"               value: length(car);
		monitor "Garage Occupancy %"        value: int(garage_occupancy_pct);
		monitor "Street Occupancy %"        value: int(street_occupancy_pct);
		monitor "Residents → Garage"        value: residents_parked_garage;
		monitor "Residents → Street (spill)" value: residents_parked_street;
		monitor "Visitors → Street"         value: visitors_parked_street;
		monitor "Overflow (left w/o parking)" value: overflow_left;
		monitor "Garages w/ Space"          value: length(garage where (each.has_space));

		display "Gowanus — Garage Scenarios" type: 2d background: #white {
			species water_body;
			species road;
			species street_spot;
			species garage;
			species bid_boundary;
			species car;
		}

		display "Garage vs Street Occupancy" type: 2d {
			chart "Occupancy Over Time (%)" type: series
				size: {1.0, 0.34} position: {0.0, 0.0} {
				data "Garage occupancy %"
					value: garage_occupancy_pct color: #forestgreen style: line;
				data "Street occupancy %"
					value: street_occupancy_pct color: #steelblue style: line;
			}
			chart "Parking by Destination" type: series
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
				data "Cumulative overflow"
					value: overflow_left color: #red style: line;
			}
		}
	}
}
