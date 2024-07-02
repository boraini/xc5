extends PuppetTrait

const VRM_ANIMATION_PLAYER := "anim"

const CONFIG_VALUES := [
    "blink_threshold",
    "link_eye_blinks",
    "use_raw_eye_rotation",
    "use_blend_shapes_for_blinking"
]

var vrm_meta: Dictionary

var left_eye_id: int
var right_eye_id: int

#region Eye data

var blink_threshold: float
var link_eye_blinks: bool
var use_raw_eye_rotation: bool
var use_blend_shapes_for_blinking: bool

class EyeClamps:
    var up: MorphData
    var down: MorphData
    var left: MorphData
    var right: MorphData

var left_eye := EyeClamps.new()
var right_eye := EyeClamps.new()

#endregion

#region Expressions

class MorphData:
    var mesh: MeshInstance
    var morph: String
    var values: Array

class ExpressionData:
    var morphs := {} # Name: String -> Array[MorphData]

    func add_morph(morph_name: String, morph_data: MorphData) -> void:
        if not morphs.has(morph_name):
            morphs[morph_name] = []
        
        morphs[morph_name].append(morph_data)

    func get_expression(morph_name: String) -> Array:
        return morphs.get(morph_name, [])

var expression_data := ExpressionData.new()

var blink_l: MorphData
var blink_r: MorphData

# Used for toggling on/off expressions
var last_morph: MorphData

#endregion

#region Mouth shapes

var current_mouth_shape: MorphData

var a_shape: MorphData
var e_shape: MorphData
var i_shape: MorphData
var o_shape: MorphData
var u_shape: MorphData

#endregion

#-----------------------------------------------------------------------------#
# Builtin functions                                                           #
#-----------------------------------------------------------------------------#

func _ready() -> void:
    for i in CONFIG_VALUES:
        AM.ps.connect(i, self, "_on_model_config_changed", [i])
    # TODO Not really sure how to make sure this signal exists
    # Maybe connect VRM model to this signal using the gui or the runner?
    if AM.ps.has_user_signal("blend_shape"):
        AM.ps.connect("blend_shape", self, "_on_blend_shape")

    has_custom_update = true

    for i in CONFIG_VALUES:
        set(i, AM.cm.model_config.get_data(i))

    var anim_player: AnimationPlayer = find_node(VRM_ANIMATION_PLAYER)

    for animation_name in anim_player.get_animation_list():
        var animation: Animation = anim_player.get_animation(animation_name)

        for track_idx in animation.get_track_count():
            var track_name: String = animation.track_get_path(track_idx)
            var split_name: PoolStringArray = track_name.split(":")

            if split_name.size() != 2:
                AM.logger.info("Model has ultra nested meshes: %s" % track_name)
                continue

            var mesh = get_node_or_null(split_name[0])
            if not mesh:
                AM.logger.info("Unable to find mesh: %s" % split_name[0])
                continue

            var md := MorphData.new()
            md.mesh = mesh
            md.morph = split_name[1]

            for key_idx in animation.track_get_key_count(track_idx):
                md.values.append(animation.track_get_key_value(track_idx, key_idx))

            expression_data.add_morph(animation_name.to_lower(), md)

    anim_player.queue_free()

    _map_bones_and_eyes()

    _fix_additional_bones()

    blink_l = expression_data.get_expression("blink_l")[0] # TODO this is kind of gross?
    blink_r = expression_data.get_expression("blink_r")[0]

    # TODO hard coded until lip sync is re-implemented
    current_mouth_shape = a_shape

    a_pose()

#-----------------------------------------------------------------------------#
# Connections                                                                 #
#-----------------------------------------------------------------------------#

func _on_model_config_changed(value: SignalPayload, key: String) -> void:
    match key:
        "blink_threshold":
            blink_threshold = value.data
        "link_eye_blinks":
            link_eye_blinks = value.data
        "use_raw_eye_rotation":
            use_raw_eye_rotation = value.data
        "use_blend_shapes_for_blinking":
            use_blend_shapes_for_blinking = value.data

func _on_blend_shape(value: String) -> void:
    var ed = get(value)
    if ed == null:
        ed = expression_data.get_expression(value)
        if ed == null:
            return

    # Undo the last expression
    if last_morph:
        for idx in last_morph.morphs.size():
            _modify_blend_shape(last_morph.morphs[idx].mesh, last_morph.morphs[idx].morph,
                last_morph.morphs[idx].values[0])

    if ed == last_morph:
        last_morph = null
        return

    for idx in ed.morphs.size():
        _modify_blend_shape(ed.morphs[idx].mesh, ed.morphs[idx].morph,
                ed.morphs[idx].values[1])

    last_morph = ed

#-----------------------------------------------------------------------------#
# Private functions                                                           #
#-----------------------------------------------------------------------------#

func _setup_logger() -> void:
    logger = Logger.new("VRMModel")

func _map_bones_and_eyes() -> void:
    if head_bone_id < 0 and vrm_meta.humanoid_bone_mapping.has("head"):
        head_bone = vrm_meta.humanoid_bone_mapping["head"]
        head_bone_id = skeleton.find_bone(head_bone)

        AM.ps.publish("head_bone", head_bone)

    var left_eye_name: String = vrm_meta.humanoid_bone_mapping.get("leftEye", "eye_L")
    left_eye_id = skeleton.find_bone(left_eye_name)
    if left_eye_id < 0:
        logger.error("No left eye found")

    var right_eye_name: String = vrm_meta.humanoid_bone_mapping.get("rightEye", "eye_R")
    right_eye_id = skeleton.find_bone(right_eye_name)
    if right_eye_id < 0:
        logger.error("No right eye found")

    if vrm_meta.humanoid_bone_mapping.has("neck"):
        var neck_bone_id: int = skeleton.find_bone(vrm_meta.humanoid_bone_mapping["neck"])
        if neck_bone_id >= 0:
            additional_bones.append(neck_bone_id)

    if vrm_meta.humanoid_bone_mapping.has("spine"):
        var spine_bone_id: int = skeleton.find_bone(vrm_meta.humanoid_bone_mapping["spine"])
        if spine_bone_id >= 0:
            additional_bones.append(spine_bone_id)
    
    # TODO getting morph data for look<direction> shapes needs to be refactored

    for morph_data in expression_data.get_expression("lookup"):
        var val = morph_data.values.back()
        if val != null:
            logger.info("adding eye rotation blend shapes")
            logger.info(left_eye_name)
            logger.info(morph_data.morph)
            # var rot = val.rotation.get_euler() if val is Dictionary else Vector3.ZERO
            match morph_data.morph:
                left_eye_name:
                    logger.info("picked left eye")
                    left_eye.up = morph_data
                right_eye_name:
                    logger.info("picked right eye")
                    right_eye.up = morph_data

    for morph_data in expression_data.get_expression("lookdown"):
        var val = morph_data.values.back()
        if val != null:
            # var rot = val.rotation.get_euler() if val is Dictionary else Vector3.ZERO
            match morph_data.morph:
                left_eye_name:
                    left_eye.down = morph_data
                right_eye_name:
                    right_eye.down = morph_data

    for morph_data in expression_data.get_expression("lookleft"):
        var val = morph_data.values.back()
        if val != null:
            # var rot = val.rotation.get_euler() if val is Dictionary else Vector3.ZERO
            match morph_data.morph:
                left_eye_name:
                    left_eye.left = morph_data
                right_eye_name:
                    right_eye.left = morph_data

    for morph_data in expression_data.get_expression("lookright"):
        var val = morph_data.values.back()
        if val != null:
            # var rot = val.rotation.get_euler() if val is Dictionary else Vector3.ZERO
            match morph_data.morph:
                left_eye_name:
                    left_eye.right = morph_data
                right_eye_name:
                    right_eye.right = morph_data

    # Some models don't have blendshapes for looking up/down/left/right
    # So let their eyes rotate 360 degrees
    # if left_eye.down.x == 0:
    # 	left_eye.down.x = -360.0
    # if left_eye.up.x == 0:
    # 	left_eye.up.x = 360.0
    # if left_eye.right.y == 0:
    # 	left_eye.right.y = -360.0
    # if left_eye.left.y == 0:
    # 	left_eye.left.y = 360.0

    # if right_eye.down.x == 0:
    # 	right_eye.down.x = -360.0
    # if right_eye.up.x == 0:
    # 	right_eye.up.x = 360.0
    # if right_eye.right.y == 0:
    # 	right_eye.right.y = -360.0
    # if right_eye.left.y == 0:
    # 	right_eye.left.y = 360.0

func _fix_additional_bones() -> void:
    """
    VRM models should not have 'root' assigned as tracked
    """
    var bone_to_remove: int = -1
    for bone_idx in additional_bones:
        if skeleton.get_bone_name(bone_idx) == "root":
            bone_to_remove = bone_idx
            break
    if bone_to_remove >= 0:
        additional_bones.erase(bone_to_remove)

#-----------------------------------------------------------------------------#
# Public functions                                                            #
#-----------------------------------------------------------------------------#
func get_eye_values(rotation: float, max_rotation: float) -> Array:
    var value: float = abs(rotation) / max_rotation
    if rotation < 0:
        return [0, value]
    else:
        return [value, 0]
    
func custom_update(i_data: InterpolationData) -> void:
    # NOTE Eye mappings are intentionally reversed so that the model mirrors the data

    #region Blinking

    # TODO add way to lock blinking for a certain expression

    if use_blend_shapes_for_blinking:
        for x in expression_data.get_expression("blink_r"):
            _modify_blend_shape(x.mesh, x.morph, x.values[1] - i_data.right_blink.target_value)
        for x in expression_data.get_expression("blink_l"):
            _modify_blend_shape(x.mesh, x.morph, x.values[1] - i_data.left_blink.target_value)
    else:
        var left_eye_open: float = i_data.left_blink.target_value
        var right_eye_open: float = i_data.right_blink.target_value

        if link_eye_blinks:
            var average_eye_open = (left_eye_open + right_eye_open) / 2
            left_eye_open = average_eye_open
            right_eye_open = average_eye_open

        if left_eye_open >= blink_threshold:
            for x in expression_data.get_expression("blink_r"):
                _modify_blend_shape(x.mesh, x.morph, x.values[1] - i_data.left_blink.interpolate(
                    i_data.left_blink.interpolation_rate))
        else:
            for x in expression_data.get_expression("blink_r"):
                _modify_blend_shape(x.mesh, x.morph, x.values[1])

        if right_eye_open >= blink_threshold:
            for x in expression_data.get_expression("blink_l"):
                _modify_blend_shape(x.mesh, x.morph, x.values[1] - i_data.right_blink.interpolate(
                    i_data.right_blink.interpolation_rate))
        else:
            for x in expression_data.get_expression("blink_l"):
                _modify_blend_shape(x.mesh, x.morph, x.values[1])

    #endregion

    #region Gaze

    var left_eye_rotation: Vector3 = i_data.left_gaze.interpolate(
        i_data.left_gaze.interpolation_rate)
    var right_eye_rotation: Vector3 = i_data.right_gaze.interpolate(
        i_data.right_gaze.interpolation_rate)
    # var average_eye_y_rotation: float = (left_eye_rotation.y + right_eye_rotation.y) / 2.0
    # left_eye_rotation.y = average_eye_y_rotation
    # right_eye_rotation.y = average_eye_y_rotation

    # TODO make this toggleable from the ui
    # var average_eye_x_rotation: float = (left_eye_rotation.x + right_eye_rotation.x) / 2.0
    # left_eye_rotation.x = average_eye_x_rotation
    # right_eye_rotation.x = average_eye_x_rotation

    # CUSTOM EYE ROTATION BLEND SHAPE CODE

    var values_horizontal: Array = get_eye_values(left_eye_rotation.y, PI / 2)
    var values_vertical: Array = get_eye_values(left_eye_rotation.x, PI / 2)
    # _modify_blend_shape(left_eye.up.mesh, left_eye.up.morph, values_vertical[0])
    # _modify_blend_shape(left_eye.down.mesh, left_eye.down.morph, values_vertical[1])

    for x in expression_data.get_expression("lookleft"):
        _modify_blend_shape(x.mesh, x.morph, values_horizontal[0])

    for x in expression_data.get_expression("lookright"):
        _modify_blend_shape(x.mesh, x.morph, values_horizontal[1])

    # _modify_blend_shape(left_eye.up.mesh, left_eye.up.morph, 1)
    # _modify_blend_shape(left_eye.down.mesh, left_eye.down.morph, 0)

    # _modify_blend_shape(left_eye.left.mesh, left_eye.left.morph, values_horizontal[0])
    # _modify_blend_shape(left_eye.right.mesh, left_eye.right.morph, values_horizontal[1])

    for x in expression_data.get_expression("lookup"):
        _modify_blend_shape(x.mesh, x.morph, values_vertical[0])

    for x in expression_data.get_expression("lookdown"):
        _modify_blend_shape(x.mesh, x.morph, values_vertical[1])
    # _modify_blend_shape(right_eye.up.mesh, right_eye.up.morph, values_vertical2[0])
    # _modify_blend_shape(right_eye.down.mesh, right_eye.down.morph, values_vertical2[1])

    # _modify_blend_shape(right_eye.left.mesh, right_eye.left.morph, values_horizontal2[0])
    # _modify_blend_shape(right_eye.right.mesh, right_eye.right.morph, values_horizontal2[1])

    # if not use_raw_eye_rotation:
    # 	left_eye_rotation.x = clamp(left_eye_rotation.x, left_eye.down.x, left_eye.up.x)
    # 	left_eye_rotation.y = clamp(left_eye_rotation.y, left_eye.right.y, left_eye.left.y)

    # 	right_eye_rotation.x = clamp(right_eye_rotation.x, right_eye.down.x, right_eye.up.x)
    # 	right_eye_rotation.y = clamp(right_eye_rotation.y, right_eye.right.y, right_eye.left.y)

    # Left eye gaze
    # var left_eye_transform := Transform()
    # left_eye_transform = left_eye_transform.rotated(Vector3.UP, left_eye_rotation.y)
    # left_eye_transform = left_eye_transform.rotated(Vector3.RIGHT, -left_eye_rotation.x)

    # Right eye gaze
    # var right_eye_transform := Transform()
    # right_eye_transform = right_eye_transform.rotated(Vector3.UP, right_eye_rotation.y)
    # right_eye_transform = right_eye_transform.rotated(Vector3.RIGHT, -right_eye_rotation.x)
    
    # NOTE: Intentionally mirrored
    # skeleton.set_bone_pose(right_eye_id, left_eye_transform)
    # skeleton.set_bone_pose(left_eye_id, right_eye_transform)

    #endregion

    #region Mouth tracking
        
    var mouth_open: float = i_data.mouth_open.interpolate(i_data.mouth_open.interpolation_rate)

    var mouth_wide: float = i_data.mouth_wide.interpolate(i_data.mouth_wide.interpolation_rate)

    # TODO workaround until lip syncing is re-implemented

    # var mouth_scale_x: int = 0
    # var mouth_scale_y: int = 0
    
    # if mouth_open < AM.cm.model_config.mouth_open_max * AM.cm.model_config.mouth_open_group_1:
    # 	mouth_scale_x = 1
    # elif mouth_open <= AM.cm.model_config.mouth_open_max * AM.cm.model_config.mouth_open_group_2:
    # 	mouth_scale_x = 2
    # else:
    # 	mouth_scale_x = 3

    # if mouth_wide < AM.cm.model_config.mouth_wide_max * AM.cm.model_config.mouth_wide_group_1:
    # 	mouth_scale_y = 1
    # elif mouth_wide <= AM.cm.model_config.mouth_wide_max * AM.cm.model_config.mouth_wide_group_2:
    # 	mouth_scale_y = 2
    # else:
    # 	mouth_scale_y = 3

    # var last_shape = current_mouth_shape

    # match mouth_scale_x:
    # 	1:
    # 		match mouth_scale_y:
    # 			1:
    # 				current_mouth_shape = u_shape
    # 			2:
    # 				# current_mouth_shape = e
    # 				pass
    # 			3:
    # 				current_mouth_shape = i_shape
    # 	2:
    # 		current_mouth_shape = e_shape
    # 	3:
    # 		match mouth_scale_y:
    # 			1:
    # 				current_mouth_shape = o_shape
    # 			2:
    # 				# current_mouth_shape = e
    # 				pass
    # 			3:
    # 				current_mouth_shape = a_shape

    # if current_mouth_shape != last_shape:
    # 	for x in last_shape.morphs:
    # 		_modify_blend_shape(x.mesh, x.morph, 0)

    # for x in current_mouth_shape.morphs:
    # 	_modify_blend_shape(x.mesh, x.morph, min(max(x.values[0], mouth_open), x.values[1]))

    # TODO workaround until lipsync is reimplemented
    for x in expression_data.get_expression("a"):
        _modify_blend_shape(x.mesh, x.morph, min(max(x.values[0], mouth_open), x.values[1]))

    #endregion

func a_pose() -> void:
    if vrm_meta.humanoid_bone_mapping.has("leftShoulder"):
        skeleton.set_bone_pose(skeleton.find_bone(vrm_meta.humanoid_bone_mapping["leftShoulder"]),
                Transform(Quat(0, 0, 0.1, 0.85)))
    if vrm_meta.humanoid_bone_mapping.has("rightShoulder"):
        skeleton.set_bone_pose(skeleton.find_bone(vrm_meta.humanoid_bone_mapping["rightShoulder"]),
                Transform(Quat(0, 0, -0.1, 0.85)))

    if vrm_meta.humanoid_bone_mapping.has("leftUpperArm"):
        skeleton.set_bone_pose(skeleton.find_bone(vrm_meta.humanoid_bone_mapping["leftUpperArm"]),
                Transform(Quat(0, 0, 0.4, 0.85)))
    if vrm_meta.humanoid_bone_mapping.has("rightUpperArm"):
        skeleton.set_bone_pose(skeleton.find_bone(vrm_meta.humanoid_bone_mapping["rightUpperArm"]),
                Transform(Quat(0, 0, -0.4, 0.85)))
