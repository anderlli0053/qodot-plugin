class_name QodotMap
extends QodotSpatial
tool

### Spatial node for rendering a QuakeMap resource into an entity/brush tree

enum StaticLightingBuildType {
	NONE,
	UNWRAP_UV2
}

# Pseudo-button for forcing a refresh after asset reimport
export(bool) var reload setget set_reload

# Print profiling data to the log if true
export(bool) var print_to_log

export(String) var map = QodotUtil.CATEGORY_STRING

# .map Resource to auto-load when updating the map from the editor
# (Works around references being held and preventing refresh on reimport)
export(String, FILE, '*.map') var map_file setget set_map_file

# Factor to scale the .map file's quake units down by
# (16 is a best-effort conversion from Quake 3 units to metric)
export(float) var inverse_scale_factor = 16.0

# Entity definitions
export(String) var entities = QodotUtil.CATEGORY_STRING
export(Resource) var entity_definitions = preload('res://addons/qodot/fgd/qodot_fgd.tres')

# Textures
export(String) var textures = QodotUtil.CATEGORY_STRING
export(String, DIR) var base_texture_path = 'res://textures'
export(String) var texture_extension = '.png'
export(Array, String, FILE, "*.wad") var texture_wads = []

# Materials
export(String) var materials = QodotUtil.CATEGORY_STRING
export(String) var material_extension = '.tres'
export (SpatialMaterial) var default_material

# Build options
export(String) var build = QodotUtil.CATEGORY_STRING

export(bool) var build_brush_entities = true
export(bool) var build_point_entities = true
export(StaticLightingBuildType) var static_lighting_build_type = StaticLightingBuildType.NONE

export(bool) var use_custom_build_pipeline = false
export(Script) var custom_build_pipeline= preload('res://addons/qodot/src/build/pipeline/debug_pipeline.gd')

# Threads
export(String) var threading = QodotUtil.CATEGORY_STRING
export(int) var max_build_threads = 4
export(int) var build_bucket_size = 4

# Instances
var build_thread = Thread.new()
var build_profiler = null

## Setters
func set_reload(new_reload = true):
	if reload != new_reload:
		if Engine.is_editor_hint():
			reload()

func reload(ignore = null):
	if build_thread.is_active():
		print("Skipping reload: Build in progress")
		return

	clear_map()

	if not map_file:
		print("Skipping reload: No map file")
		return

	build_profiler = QodotProfiler.new()
	build_thread.start(self, "build_map", map_file)

func set_map_file(new_map_file: String):
	if(map_file != new_map_file):
		map_file = new_map_file

func set_texture_wads(new_texture_wads):
	var tw = Array(new_texture_wads)
	if(texture_wads != tw):
		texture_wads = tw
		print(texture_wads)

func print_log(msg):
	if(print_to_log):
		QodotPrinter.print_typed(msg)

func _exit_tree():
	if(build_thread.is_active()):
		build_thread.wait_to_finish()

# Clears any existing children
func clear_map():
	for child in get_children():
		var should_remove = false

		var child_script = child.get_script()
		if child_script:
			if child_script == QodotNode || child_script == QodotSpatial:
				should_remove = true
			else:
				var child_base_script = child_script.get_base_script()
				while child_base_script:
					var next_base = child_base_script.get_base_script()
					if next_base:
						child_base_script = next_base
					else:
						break

				if child_base_script:
					if child_base_script == QodotNode || child_base_script == QodotSpatial:
						should_remove = true

		if should_remove:
			remove_child(child)
			child.queue_free()

# Kicks off the building process
func build_map(map_file: String) -> void:
	print("\nBuilding map...\n")

	var context = {
		"map_file": map_file,
		"base_texture_path": base_texture_path,
		"material_extension": material_extension,
		"texture_extension": texture_extension,
		"texture_wads": texture_wads,
		"default_material": default_material,
		"inverse_scale_factor": inverse_scale_factor
	}

	# Initialize thread pool
	print_log("\nInitializing Thread Pool...")
	var thread_init_profiler = QodotProfiler.new()
	var thread_pool = QodotThreadPool.new()
	thread_pool.set_max_threads(max_build_threads)
	thread_pool.set_bucket_size(build_bucket_size)
	context['thread_pool'] = thread_pool
	var thread_init_duration = thread_init_profiler.finish()
	print_log("Done in " + String(thread_init_duration * 0.001) + " seconds.\n")

	# Loading entity defintions
	print_log("\nLoading entity definition set...")
	var entity_set = {}
	if entity_definitions != null:
		entity_set = entity_definitions.get_entity_scene_map()
	context["entity_definition_set"] = entity_set

	# Run build steps
	var build_steps = get_build_steps()

	for build_step_idx in range(0, build_steps.size()):
		var build_step = build_steps[build_step_idx]
		var step_name = build_step.get_name()

		if not queue_build_step(context, build_step):
			print('Error: failed to queue build step.')
			call_deferred('cleanup_thread_pool', context, thread_pool)
			call_deferred("build_failed")
			return

		print_log("Building " + build_step.get_name() + "...")
		var job_profiler = QodotProfiler.new()
		thread_pool.start_thread_jobs()
		var results = yield(thread_pool, "jobs_complete")

		add_context_results(context, results)
		var job_duration = job_profiler.finish()
		print_log("Done in " + String(job_duration * 0.001) + " seconds.\n")

	call_deferred('cleanup_thread_pool', context, thread_pool)
	call_deferred("finalize_build", context, build_steps)

func get_build_steps() -> Array:
	var build_steps = []

	if use_custom_build_pipeline:
		build_steps = custom_build_pipeline.get_build_steps()
	else:
		build_steps = [
			QodotBuildParseMap.new(),
			QodotBuildTextureList.new(),
		]

		var visual_build_steps = [
			QodotBuildTextures.new(),
			QodotBuildTextureAtlas.new(),
			QodotBuildMaterials.new(),
		]

		var brush_entity_build_steps = []
		if build_brush_entities:
			brush_entity_build_steps = [
				QodotBuildNode.new("brush_entities_node", "Brush Entities", QodotSpatial),
				QodotBuildBrushEntityNodes.new(),
				QodotBuildBrushEntityPhysicsBodies.new(),
				QodotBuildBrushEntityMaterialMeshes.new(),
				QodotBuildBrushEntityAtlasedMeshes.new(),
				QodotBuildBrushEntityCollisionShapes.new(),
			]

		var entity_spawn_build_steps = []
		if build_point_entities:
				entity_spawn_build_steps = [
					QodotBuildNode.new("point_entities_node", "Point Entities", QodotSpatial),
					QodotBuildPointEntities.new(),
				]

		var static_lighting_build_steps = []
		match static_lighting_build_type:
			StaticLightingBuildType.UNWRAP_UV2:
				static_lighting_build_steps = [
					QodotBuildUnwrapUVs.new(),
				]

		var build_step_arrays = [
			visual_build_steps,
			brush_entity_build_steps,
			entity_spawn_build_steps,
			static_lighting_build_steps
		]

		for build_step_array in build_step_arrays:
			for build_step in build_step_array:
				build_steps.append(build_step)

	return build_steps

func cleanup_thread_pool(context, thread_pool):
	print_log("Cleaning up thread pool...")
	var thread_cleanup_profiler = QodotProfiler.new()
	context.erase('thread_pool')
	thread_pool.finish()
	var thread_cleanup_duration = thread_cleanup_profiler.finish()
	print_log("Done in " + String(thread_cleanup_duration * 0.001) + " seconds...\n")

var prev_node = self

func add_context_results(context: Dictionary, results):
	for result_key in results:
		var result = results[result_key]
		if result:
			for data_key in result:
				if data_key == 'nodes':
					add_context_nodes_recursive(context, data_key, result[data_key])
				else:
					add_context_data_recursive(context, data_key, result[data_key])

			var prev_node = self

func add_context_data_recursive(context: Dictionary, data_key, result):
	if not data_key in context:
		context[data_key] = result
	else:
		for result_key in result:
			var data = result[result_key]
			add_context_data_recursive(context[data_key], result_key, data)

func add_context_nodes_recursive(context: Dictionary, context_key: String, nodes: Dictionary):
	for node_key in nodes:
		var node = nodes[node_key]
		if node is Dictionary:
			if 'node' in context[context_key]:
				prev_node = context[context_key]['node']
			add_context_nodes_recursive(context[context_key]['children'], node_key, node)
		else:
			if not context_key in context:
				context[context_key] = {
					'children': {}
				}
			var is_instanced_scene = false
			if node is QodotBuildPointEntities.InstancedScene:
				node = node.wrapped_node
				is_instanced_scene = true

			context[context_key]['children'][node_key] = {
				'node': node,
				'children': {}
			}

			if 'node' in context[context_key]:
				context[context_key]['node'].add_child(node)
			else:
				prev_node.add_child(node)

			if is_instanced_scene:
				node.owner = get_tree().get_edited_scene_root()
			else:
				recursive_set_owner(node, get_tree().get_edited_scene_root())


# Queues a build step for execution
func queue_build_step(context: Dictionary, build_step: QodotBuildStep):
	var build_step_type = build_step.get_type()

	var thread_pool = context['thread_pool']

	var step_context = {}
	for build_step_param_name in build_step.get_build_params():
		if not build_step_param_name in context:
			print("Error: Requested parameter " + build_step_param_name + " not present in context for build step " + build_step.get_name())
			return false

		if build_step_param_name == "thread_pool":
			print("Error: Build steps cannot require the thread pool as a parameter")
			return false

		step_context[build_step_param_name] = context[build_step_param_name]

	print_log("Queueing " + build_step.get_name() + " for building...")

	if build_step_type == QodotBuildStep.Type.SINGLE:
		thread_pool.add_thread_job(build_step, "_run", step_context)
	else:
		var entity_properties_array = context['entity_properties_array']
		for entity_idx in range(0, entity_properties_array.size()):
			var entity_context = step_context.duplicate()
			entity_context['entity_idx'] = entity_idx
			entity_context['entity_properties'] = entity_properties_array[entity_idx]

			if build_step_type == QodotBuildStep.Type.PER_ENTITY:
				thread_pool.add_thread_job(build_step, "_run", entity_context)
			elif build_step_type == QodotBuildStep.Type.PER_BRUSH:
				var brush_data_dict = context['brush_data_dict']
				for brush_idx in brush_data_dict[entity_idx]:
					var brush_context = entity_context.duplicate()
					brush_context['brush_idx'] = brush_idx
					brush_context['brush_data'] = brush_data_dict[entity_idx][brush_idx]
					thread_pool.add_thread_job(build_step, "_run", brush_context)

	print_log("Done.\n")
	return true

func build_failed():
	build_thread.wait_to_finish()
	print("Build failed.")

func finalize_build(context: Dictionary, build_steps: Array):
	build_thread.wait_to_finish()

	for build_step in build_steps:
		if build_step.get_wants_finalize():
			run_finalize_step(context, build_step)

	build_complete()

func run_finalize_step(context: Dictionary, build_step: QodotBuildStep) -> void:
	var build_step_name = build_step.get_name()

	var step_context = {}
	for build_step_param_name in build_step.get_finalize_params():
		if not build_step_param_name in context:
			print("Error: Requested parameter " + build_step_param_name + " not present in context for build step " + build_step.get_name())
			continue
		step_context[build_step_param_name] = context[build_step_param_name]

	print_log("Finalizing " + build_step.get_name() + "...")
	var finalize_profiler = QodotProfiler.new()
	var finalize_result = build_step._finalize(step_context)
	add_context_results(context, {0: finalize_result})
	var finalize_duration = finalize_profiler.finish()
	print_log("Done in " + String(finalize_duration * 0.001) + " seconds.\n")

# Build completion handler
func build_complete() -> void:
	var build_duration = build_profiler.finish()
	print("Build complete after " + String(build_duration * 0.001) + " seconds.\n")

func add_children_to_editor(edited_scene_root) -> void:
	for child in get_children():
		recursive_set_owner(child, edited_scene_root)

func recursive_set_owner(node, new_owner) -> void:
	if not node.get_parent() is QodotTextureLayeredMesh:
		node.set_owner(new_owner)

	for child in node.get_children():
		recursive_set_owner(child, new_owner)
