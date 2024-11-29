class Game
  attr_gtk

  def tick
    defaults
    outputs.background_color = [ 0x92, 0xcc, 0xf0 ]
    send(@current_scene)

    # outputs.debug.watch state
    # outputs.watch "#{$gtk.current_framerate} FPS"
    #outputs.debug.watch "tick count: #{@clock}"

    # has there been a scene change ?
    if @next_scene
      @current_scene = @next_scene
      @next_scene = nil
    end
  end

  def tick_title_scene
    audio[:menu_music].paused = false

    outputs.labels << { x: 640, y: 360, text: "Title Scene (click or tap to begin)", alignment_enum: 1 }

    if $gtk.args.inputs.mouse.click
      @next_scene = :tick_game_scene
      audio[:menu_music].paused = true
      audio[:music].paused = false
      audio[:wind].paused = false
      @clock = 0
    end
  end

  def tick_game_scene
    input
    calc
    outputs.primitives << self

    # Hack, draw minimap here instead of in main render method
    draw_minimap

    if $gtk.args.inputs.mouse.click
      @next_scene = :tick_game_over_scene
      audio[:music].paused = true
      audio[:wind].paused = true
    end

    @timer = (21 - @clock / 60.0).to_i
    draw_hud

    if @timer <= 0
      @current_scene = :tick_game_over_scene
    end
  end

  def tick_game_over_scene
    outputs.labels << { x: 640, y: 360, text: "Game Over !", alignment_enum: 1 }

    if $gtk.args.inputs.mouse.click
      @next_scene = :tick_title_scene
      @defaults_set = false
    end
  end

  def input
    return if game_has_lost_focus?

    dx = inputs.left_right_perc
    dy = inputs.up_down_perc

    # Normalize the input so diagonal movements aren't faster
    if dx != 0 || dy != 0
      l = 1.0 / Math.sqrt(dx * dx + dy * dy)
      dx *= l
      dy *= l
    end

    @player[:vx] = (@player[:vx] + dx * @player[:speed]).clamp(-@player[:max_speed], @player[:max_speed])
    @player[:vy] = (@player[:vy] + dy * @player[:speed]).clamp(-@player[:max_speed], @player[:max_speed])

    # Check if the spacebar is pressed and 3 seconds have passed since the last boost
    if inputs.keyboard.key_down.space && (args.state.tick_count - @player[:last_boost_time]) >= 180  # 180 ticks = 3 seconds
      player_boost
      @last_boost_time = args.state.tick_count
    end

    @player_flip = false if dx > 0
    @player_flip = true if dx < 0
  end

  def player_boost
    return if @player[:boosting]
    return if @player[:coins] == 0

    @player[:coins] -= 1

    @player[:boosting] = true
    @player[:boost_remaining] = @player[:boost_duration]

    magnitude = Math.sqrt(@player[:vx]**2 + @player[:vy]**2)
    return if magnitude == 0

    @player[:dx] = @player[:vx] / magnitude
    @player[:dy] = @player[:vy] / magnitude


  end

  def calc_player
    # Slowly increase upward velocity
    @player[:vy] += @player[:rising]

    @player[:x] += @player[:vx]
    @player[:y] += @player[:vy]
    @player[:vx] *= @player[:damping]
    @player[:vy] *= @player[:damping]


    if @player[:boosting]
      boost_increment = @player[:boost] / @player[:boost_duration]
      @player[:vx] += @player[:dx] * boost_increment
      @player[:vy] += @player[:dy] * boost_increment
      @player[:boost_remaining] -= 1

      if @player[:boost_remaining] <= 0
        @player[:boosting] = false
      end
    end

    # Warp player
    if (@player[:x] - @player[:w] * 0.5) < 0
      @player[:x] += @maze_width * @maze_cell_w
      @camera[:x] += @maze_width * @maze_cell_w
      @camera_teleport_offset[:x] -= @maze_width * @maze_cell_w
    end

    if (@player[:x] + @player[:w] * 0.5) > @maze_width * @maze_cell_w
      @player[:x] -= @maze_width * @maze_cell_w
      @camera[:x] -= @maze_width * @maze_cell_w
      @camera_teleport_offset[:x] += @maze_width * @maze_cell_w
    end
  end

  def calc_camera
    tx = @player[:x]
    ty = @player[:y] + @screen_height * @camera[:offset_y] / @camera[:zoom]

    @camera[:x] = @camera[:x].lerp(tx, @camera[:lag])
    @camera[:y] = @camera[:y].lerp(ty, @camera[:lag])

    # Adjust camera zoom based on player velocity
    player_velocity = Math.sqrt(@player[:vx] * @player[:vx] + @player[:vy] * @player[:vy]) / @player[:max_speed]
    target_zoom = 1.0 - 0.1 * player_velocity  # Zoom out more as speed increases
    @camera[:zoom] = @camera[:zoom].lerp(target_zoom, @camera[:zoom_speed])  # Smooth transition with lerp

    @viewport = {
      x: @camera[:x] - @screen_width / (2 * @camera[:zoom]),
      y: @camera[:y] - @screen_height / (2 * @camera[:zoom]),
      w: @screen_width / @camera[:zoom],
      h: @screen_height / @camera[:zoom]
    }

    @wrapped_viewport = nil

    if @viewport[:x] + @viewport[:w] > @maze_width * @maze_cell_w
      @wrapped_viewport = @viewport.merge(x: @viewport[:x] - @maze_width * @maze_cell_w, position: :right)
    end

    if @viewport[:x] < 0
      @wrapped_viewport = @viewport.merge(x: @viewport[:x] + @maze_width * @maze_cell_w, position: :left)
    end
  end
  def calc
    return if game_has_lost_focus?

    calc_player
    calc_camera

    # Calc birds
    try_create_bird
    calc_birds

    # Handle collision
    handle_wall_collision
    handle_item_collision

    # Calc Wind
    new_wind_gain = Math.sqrt(@player[:vx] * @player[:vx] + @player[:vy] * @player[:vy]) * @wind_gain_multiplier
    audio[:wind].gain = audio[:wind].gain.lerp(new_wind_gain, @wind_gain_speed)

    # Scroll clouds
    @bg_x -= 0.2
    @clock += 1
  end

  def draw_override ffi
    draw_parallax_layer_tiles(@bg_parallax, 'sprites/cloudy_background.png', ffi)

    draw_maze(ffi)
    draw_items(ffi)
    draw_player(ffi)

    draw_birds(ffi)

    draw_parallax_layer_tiles(@bg_parallax * 1.5, 'sprites/cloudy_foreground.png', ffi, { a: 32, blendmode_enum: 2 })
  end

  def draw_parallax_layer_tiles(parallax_multiplier, image_path, ffi, render_options = {})
    # Adjust the camera position by the accumulated teleport offset
    adjusted_camera_x = @camera[:x] + @camera_teleport_offset[:x]
    adjusted_camera_y = @camera[:y] + @camera_teleport_offset[:y]

    # Calculate the parallax offset based on the adjusted camera position
    parallax_offset_x = (adjusted_camera_x * parallax_multiplier + @bg_x) % @bg_w
    parallax_offset_y = (adjusted_camera_y * parallax_multiplier + @bg_y) % @bg_h

    # Normalize negative offsets
    parallax_offset_x += @bg_w if parallax_offset_x < 0
    parallax_offset_y += @bg_h if parallax_offset_y < 0

    # Determine how many tiles are needed to cover the screen
    tiles_x = (@screen_width / @bg_w.to_f).ceil + 1
    tiles_y = (@screen_height / @bg_h.to_f).ceil + 1

    # Draw the tiles
    tile_x = 0
    while tile_x <= tiles_x
      tile_y = 0
      while tile_y <= tiles_y
        x = (tile_x * @bg_w) - parallax_offset_x
        y = (tile_y * @bg_h) - parallax_offset_y

        ffi.draw_sprite_4 x,                          # x
                          y,                          # y
                          @bg_w,                      # w
                          @bg_h,                      # h
                          image_path,                 # path
                          nil,                        # angle
                          render_options[:a] || nil,  # alpha
                          nil,                        # r
                          nil,                        # g
                          nil,                        # b
                          nil,                        # tile_x
                          nil,                        # tile_y
                          nil,                        # tile_w
                          nil,                        # tile_h
                          nil,                        # flip_horizontally
                          nil,                        # flip_vertically
                          nil,                        # angle_anchor_x
                          nil,                        # angle_anchor_y
                          nil,                        # source_x
                          nil,                        # source_y
                          nil,                        # source_w
                          nil,                        # source_h
                          render_options[:blendmode_enum] || nil
        tile_y += 1
      end
      tile_x += 1
    end
  end

  def create_maze
    @maze = Maze.prepare_grid(@maze_height, @maze_width)
    Maze.on(@maze)

    collider = { r: 255, g: 255, b: 255, a: 64, primitive_marker: :solid }

    # Create collision rects for maze
    maze_colliders = @maze.flat_map do |row|
      row.flat_map do |cell|
        x1 = cell[:col] * @maze_cell_w
        y1 = cell[:row] * @maze_cell_h
        x2 = (cell[:col] + 1) * @maze_cell_w
        y2 = (cell[:row] + 1) * @maze_cell_h

        colliders = []

        unless cell[:north]
          colliders << { x: x1, y: y1, w: @maze_cell_w, h: @wall_thickness }.merge!(collider)
        end
        unless cell[:west]
          colliders << { x: x1, y: y1, w: @wall_thickness, h: @maze_cell_h }.merge!(collider)
        end
        unless cell[:links].key? cell[:east]
          colliders << { x: x2, y: y1, w: @wall_thickness, h: @maze_cell_h }.merge!(collider)
        end
        unless cell[:links].key? cell[:south]
          colliders << { x: x1, y: y2 - @wall_thickness, w: @maze_cell_w + @wall_thickness, h: @wall_thickness }.merge!(collider)
        end

        colliders
      end
    end

    @maze_colliders_quad_tree = GTK::Geometry.quad_tree_create(maze_colliders)
  end

  def draw_maze(ffi)
    GTK::Geometry.find_all_intersect_rect_quad_tree(@viewport, @maze_colliders_quad_tree).each do |wall|
      ffi.draw_solid(x_to_screen(wall[:x]),
                     y_to_screen(wall[:y]),
                     wall[:w] * @camera[:zoom],
                     wall[:h] * @camera[:zoom],
                     wall[:r],
                     wall[:g],
                     wall[:b],
                     wall[:a])
    end

    if @wrapped_viewport
      GTK::Geometry.find_all_intersect_rect_quad_tree(@wrapped_viewport, @maze_colliders_quad_tree).each do |wall|
        map_w = @maze_width * @maze_cell_w
        map_w = @wrapped_viewport[:position] == :left ? map_w : -map_w

        ffi.draw_solid(x_to_screen(wall[:x] - map_w),
                       y_to_screen(wall[:y]),
                       wall[:w] * @camera[:zoom],
                       wall[:h] * @camera[:zoom],
                       wall[:r],
                       wall[:g],
                       wall[:b],
                       wall[:a])
      end
    end
  end

  def create_minimap
    outputs[:minimap].w = @minimap_width
    outputs[:minimap].h = @minimap_height

    outputs[:minimap].primitives << { x: 0, y: 0, w: @minimap_width, h: @minimap_height, r: 0, g: 0, b: 0, primitive_marker: :solid }

    outputs[:minimap_mask].w = @minimap_width
    outputs[:minimap_mask].h = @minimap_height
    outputs[:minimap_mask].clear_before_render = !@defaults_set

    # Draw maze as a minimap
    @maze.each do |row|
      row.each do |cell|
        x1 = cell[:col] * @minimap_cell_size
        y1 = cell[:row] * @minimap_cell_size
        x2 = (cell[:col] + 1) * @minimap_cell_size
        y2 = (cell[:row] + 1) * @minimap_cell_size
        outputs[:minimap].primitives << { x: x1, y: y1, x2: x2, y2: y1, r: 255, g: 255, b: 255, primitive_marker: :line } unless cell[:north]
        outputs[:minimap].primitives << { x: x1, y: y1, x2: x1, y2: y2, r: 255, g: 255, b: 255, primitive_marker: :line } unless cell[:west]
        outputs[:minimap].primitives << { x: x2, y: y1, x2: x2, y2: y2, r: 255, g: 255, b: 255, primitive_marker: :line } unless cell[:links].key?(cell[:east])
        outputs[:minimap].primitives << { x: x1, y: y2, x2: x2, y2: y2, r: 255, g: 255, b: 255, primitive_marker: :line } unless cell[:links].key?(cell[:south])
      end
    end
  end

  def draw_minimap
    # Normalize player's position
    normalized_player_x = @player[:x]
    normalized_player_y = @player[:y]

    # Calculate player's position in the minimap space
    minimap_player_x = normalized_player_x / @maze_cell_w * @minimap_cell_size
    minimap_player_y = normalized_player_y / @maze_cell_h * @minimap_cell_size
    
    # Draw the viewport rect into the mask
    view_rect_x = (@viewport[:w] / (@maze_width * @maze_cell_w)) * @minimap_width
    view_rect_y = (@viewport[:h] / (@maze_height * @maze_cell_h)) * @minimap_height

    outputs[:minimap_mask].clear_before_render = false
    outputs[:minimap_mask].solids << {
      x: minimap_player_x,
      y: minimap_player_y,
      w: view_rect_x,
      h: view_rect_y,
      anchor_x: 0.5,
      anchor_y: 0.5,
      r: 255,
      g: 255,
      b: 255,
      primitive_marker: :solid
    }

    # Create a combined render target of the mask and minimap
    outputs[:minimap_final].w = @minimap_width
    outputs[:minimap_final].h = @minimap_height
    outputs[:minimap_final].transient!

    # Draw the mask into the combined render target
    outputs[:minimap_final].primitives << {
      x: 0,
      y: 0,
      w: @minimap_width,
      h: @minimap_height,
      path: :minimap_mask,

      blendmode_enum: 0,
      primitive_marker: :sprite
    }

    # Draw the minimap into the combined render target
    outputs[:minimap_final].primitives << {
      x: 0,
      y: 0,
      w: @minimap_width,
      h: @minimap_height,
      path: :minimap,
      blendmode_enum: 3,
      primitive_marker: :sprite
    }

    # Draw a solid background
    outputs.primitives << {
      x: 0,
      y: 0,
      w: @minimap_width,
      h: @minimap_height,
      r: 0, g: 0, b: 0, a: 64,
      primitive_marker: :solid,
    }

    # Draw the combined render target of minimap and mask
    outputs.primitives << {
      x: 0,
      y: 0,
      w: @minimap_width,
      h: @minimap_height,
      path: :minimap_final,
      blendmode_enum: 2,
    }

    # Debug
    @minimap_revealed ||= false
    @minimap_revealed = !@minimap_revealed if args.inputs.keyboard.key_up.r && !args.gtk.production?

    @draw_bird_paths = !@draw_bird_paths if args.inputs.keyboard.key_up.p && !args.gtk.production?

    if @minimap_revealed
      outputs[:primitives] << {
        x: 0,
        y: 0,
        w: @minimap_width,
        h: @minimap_height,
        path: :minimap,
      }
    end

    # Draw player position
    outputs.primitives << {
      x: minimap_player_x,
      y: minimap_player_y,
      w: 5,
      h: 5,
      r: 255,
      g: 0,
      b: 0,
      primitive_marker: :solid,
      anchor_x: 0.5,
      anchor_y: 0.5
    }
  end

  def draw_hud
    # Timer
    args.outputs.labels << {
      x: @screen_width - 20,
      y: @screen_height - 40,
      text: "#{@timer}",
      anchor_x: 1.0,
      anchor_y: 1.0,
      size_enum: 16,
      font: 'fonts/Chango-Regular.ttf'
    }
    args.outputs.labels << {
      x: @screen_width - 21,
      y: @screen_height - 38,
      text: "#{@timer}",
      anchor_x: 1.0,
      anchor_y: 1.0,
      size_enum: 16,
      r: 255,
      g: 255,
      b: 255,
      font: 'fonts/Chango-Regular.ttf'
    }

    # Coins
    outputs.labels << {
      x: @screen_width * 0.5,
      y: @screen_height - 40,
      text: "#{@player[:coins]}",
      anchor_x: 0.5,
      anchor_y: 1.0,
      size_enum: 16,
      font: 'fonts/Chango-Regular.ttf'
    }
    outputs.labels << {
      x: @screen_width * 0.5,
      y: @screen_height - 38,
      text: "#{@player[:coins]}",
      anchor_x: 0.5,
      anchor_y: 1.0,
      size_enum: 16,
      r: 255,
      g: 255,
      b: 0,
      font: 'fonts/Chango-Regular.ttf'
    }

    coins_w, coins_h = GTK.calcstringbox("#{@player[:coins]}", 16, 'fonts/Chango-Regular.ttf')
    outputs.primitives << {
      x: @screen_width * 0.5 - coins_w - 16,
      y: @screen_height - coins_h - 15,
      w: coins_h * 0.5,
      h: coins_h * 0.5,
      anchor_y: 0.5,
      anchor_x: 0.0,
      path: 'sprites/coin.png',
      primitive_marker: :sprite,
    }
  end

  def handle_wall_collision
    player_mid_x = @player[:x]
    player_mid_y = @player[:y]
    player_half_w = @player[:w] * 0.5
    player_half_h = @player[:h] * 0.5

    walls = GTK::Geometry.find_all_intersect_rect_quad_tree(@player, @maze_colliders_quad_tree)

    if @wrapped_viewport
      maze_world_width = @maze_width * @maze_cell_w
      shifted_position = player_mid_x + (@wrapped_viewport[:position] == :left ? maze_world_width : -maze_world_width)
      walls.concat(GTK::Geometry.find_all_intersect_rect_quad_tree(@player.merge(x: shifted_position), @maze_colliders_quad_tree).map do |wall|
        wall.merge(x: wall[:x] - @maze_width * @maze_cell_w)
      end)
    end

    walls.each do |collision|
      collision_mid_x = collision[:x] + collision[:w] * 0.5
      collision_mid_y = collision[:y] + collision[:h] * 0.5
      collision_half_w = collision[:w] * 0.5
      collision_half_h = collision[:h] * 0.5

      dx = collision_mid_x - player_mid_x
      dy = collision_mid_y - player_mid_y

      overlap_x = player_half_w + collision_half_w - dx.abs
      next if overlap_x < 0

      overlap_y = player_half_h + collision_half_h - dy.abs
      next if overlap_y < 0

      if overlap_x < overlap_y
        nx = dx < 0 ? -1.0 : 1.0
        ny = 0.0
      else
        nx = 0.0
        ny = dy < 0 ? -1.0 : 1.0
      end

      # Relative velocity in the direction of the collision normal
      rvn = -(nx * @player[:vx] + ny * @player[:vy])
      next if rvn > 0

      # Calculate the impulse magnitude
      jN = -(1 + @cloud_bounciness) * rvn

      # Apply the impulse
      @player[:vx] -= jN * nx
      @player[:vy] -= jN * ny
    end
  end

  def handle_item_collision
    GTK::Geometry.find_all_intersect_rect(@player, @items).each do |item|
      if item[:item_type] == :coin
        args.audio[:coin] = { input: "sounds/coin.wav", gain: 1.5 }
        @player[:coins] += 1
        @items.delete(item)
      end
    end
  end

  def create_coins
    coin = { w: 32, h: 32, r: 255, g: 255, b: 0, item_type: :coin, anchor_x: 0.5, anchor_y: 0.5, path: 'sprites/coin.png', primitive_marker: :sprite }

    @max_coins_per_cell = 2
    @coin_chance_per_cell = 0.5
    @coins = []

    @maze.each do |row|
      row.each do |cell|
        @max_coins_per_cell.times do
          next unless rand < @coin_chance_per_cell

          loop do
            quantized_x = (cell[:col] * @maze_cell_w + @wall_thickness + coin[:w] * 0.5 + rand(@maze_cell_w - 2 * @wall_thickness) - coin[:w] * 0.5) / @wall_thickness * @wall_thickness
            quantized_y = (cell[:row] * @maze_cell_h + @wall_thickness + coin[:h] * 0.5 + rand(@maze_cell_h - 3 * @wall_thickness) - coin[:h] * 0.5) / @wall_thickness * @wall_thickness

            new_coin = coin.merge(x: quantized_x, y: quantized_y)

            # Check for overlap
            overlap = @coins.any? do |existing_coin|
              (existing_coin[:x] - new_coin[:x]).abs < @wall_thickness && (existing_coin[:y] - new_coin[:y]).abs < @wall_thickness
            end

            unless overlap
              @coins << new_coin
              break
            end
          end
        end
      end
    end
  end

  def create_items
    # TODO: add additional item arrays
    @items = [].concat(@coins)
  end

  def draw_items(ffi)
    GTK::Geometry.find_all_intersect_rect(@viewport, @items).each do |item|
      ffi.draw_sprite_5(x_to_screen(item[:x]),      # x
                        y_to_screen(item[:y]),      # y
                        item[:w] * @camera[:zoom],  # w
                        item[:h] * @camera[:zoom],  # h
                        item[:path],                # path
                        nil,                        # angle
                        nil,                        # alpha
                        nil,                        # r
                        nil,                        # g,
                        nil,                        # b
                        nil,                        # tile_x
                        nil,                        # tile_y
                        nil,                        # tile_w
                        nil,                        # tile_h
                        nil,                        # flip_horizontally
                        nil,                        # flip_vertically
                        nil,                        # angle_anchor_x
                        nil,                        # angle_anchor_y
                        nil,                        # source_x
                        nil,                        # source_y
                        nil,                        # source_w,
                        nil,                        # source_h
                        nil,                        # blendmode_enum
                        0.5,                        # anchor_x
                        0.5)                        # anchor_y
    end

    if @wrapped_viewport
      GTK::Geometry.find_all_intersect_rect(@wrapped_viewport, @items).each do |item|
        map_w = @maze_width * @maze_cell_w
        map_w = @wrapped_viewport[:position] == :left ? map_w : -map_w

        ffi.draw_sprite_5(x_to_screen(item[:x] - map_w), # x
                          y_to_screen(item[:y]), # y
                          item[:w] * @camera[:zoom], # w
                          item[:h] * @camera[:zoom], # h
                          item[:path], # path
                          nil, # angle
                          nil, # alpha
                          nil, # r
                          nil, # g,
                          nil, # b
                          nil, # tile_x
                          nil, # tile_y
                          nil, # tile_w
                          nil, # tile_h
                          @player_flip, # flip_horizontally
                          nil, # flip_vertically
                          nil, # angle_anchor_x
                          nil, # angle_anchor_y
                          nil, # source_x
                          nil, # source_y
                          nil, # source_w,
                          nil, # source_h
                          nil, # blendmode_enum
                          0.5, # anchor_x
                          0.5) # anchor_y
      end
    end
  end

  def bezier(x, y, x2, y2, x3, y3, x4, y4, step)
    step ||= 0
    color = [200, 200, 200]
    points = points_for_bezier [x, y], [x2, y2], [x3, y3], [x4, y4], step

    points.each_cons(2).map do |p1, p2|
      [p1, p2, color]
    end
  end

  def points_for_bezier(p1, p2, p3, p4, step)
    if step == 0
      [p1, p2, p3, p4]
    else
      t_step = 1.fdiv(step + 1)
      t = 0
      t += t_step
      points = []
      while t < 1
        points << [
          b_for_t(p1.x, p2.x, p3.x, p4.x, t),
          b_for_t(p1.y, p2.y, p3.y, p4.y, t),
        ]
        t += t_step
      end

      [
        p1,
        *points,
        p4
      ]
    end
  end

  def b_for_t(v0, v1, v2, v3, t)
    (1 - t) ** 3 * v0 +
      3 * (1 - t) ** 2 * t * v1 +
      3 * (1 - t) * t ** 2 * v2 +
      t ** 3 * v3
  end

  def derivative_for_t(v0, v1, v2, v3, t)
    -3 * (1 - t) ** 2 * v0 +
      3 * (1 - t) ** 2 * v1 - 6 * (1 - t) * t * v1 +
      6 * (1 - t) * t * v2 - 3 * t ** 2 * v2 +
      3 * t ** 2 * v3
  end

  def try_create_bird
    @bird ||= { w: 48, h: 32, path: 'sprites/bird/frame-1.png', anchor_x: 0.5, anchor_y: 0.5 }

    interval = @bird_spawn_interval + (rand(2 * @bird_spawn_variance + 1) - @bird_spawn_variance)

    if args.state.tick_count % interval.to_i == 0
      # Determine direction randomly
      direction = rand < 0.5 ? :left_to_right : :right_to_left

      if direction == :left_to_right
        x_start = @viewport[:x] - @bird[:w]
        x_end = @viewport[:x] + @viewport[:w] + @bird[:w]
      else
        x_start = @viewport[:x] + @viewport[:w] + @bird[:w]
        x_end = @viewport[:x] - @bird[:w]
      end

      # Pick a random start height
      y_start = @viewport[:y] + rand * @viewport[:h]

      # Predict the player's future position
      time_interval = 2.0 # Adjust this value as needed
      predicted_player_x = @player[:x] + @player[:vx] * time_interval
      predicted_player_y = @player[:y] + @player[:vy] * time_interval

      # Control points
      control_x1 = (x_start + predicted_player_x - @player[:w]) / 2
      control_y1 = (y_start + predicted_player_y - @player[:h]) / 2
      control_x2 = predicted_player_x - @player[:w]
      control_y2 = predicted_player_y - @player[:h]

      # Pick a random end height
      y_end = @viewport[:y] + rand * @viewport[:h]

      # Generate a spline path that intersects with the predicted player position
      points = bezier(x_start, y_start, control_x1, control_y1, control_x2, control_y2, x_end, y_end, 20)

      @birds << @bird.merge(
        x: x_start,
        y: y_start,
        points: points,
        spline: [[x_start, control_x1, control_x2, x_end], [y_start, control_y1, control_y2, y_end]],
        frame: 1,
        flip_vertically: direction == :right_to_left
        )
    end
  end

  def calc_birds
    @birds.reject! do |bird|
      bird[:progress] ||= 0
      bird[:progress] += 0.004 # speed

      if bird[:progress] < 1
        # Follow the spline path
        spline_x, spline_y = bird[:spline]
        bird[:x] = b_for_t(spline_x[0], spline_x[1], spline_x[2], spline_x[3], bird[:progress])
        bird[:y] = b_for_t(spline_y[0], spline_y[1], spline_y[2], spline_y[3], bird[:progress])
        dx = derivative_for_t(spline_x[0], spline_x[1], spline_x[2], spline_x[3], bird[:progress])
        dy = derivative_for_t(spline_y[0], spline_y[1], spline_y[2], spline_y[3], bird[:progress])
        bird[:angle] = Math.atan2(dy, dx) * (180 / Math::PI)
        bird[:vx] = dx * 0.005 # velocity vector scaled by speed factor
        bird[:vy] = dy * 0.005
      else
        # Continue in the current direction with the calculated velocity
        bird[:x] += bird[:vx]
        bird[:y] += bird[:vy]
      end

      # Wrap bird position around the maze
      if bird[:x] < 0
        bird[:x] += @maze_width * @maze_cell_w
      elsif bird[:x] > @maze_width * @maze_cell_w
        bird[:x] -= @maze_width * @maze_cell_w
      end


      bird[:frame] = 0.frame_index(count: 8, tick_count_override: @clock, hold_for: 3, repeat: true)

      # Calculate the wrapped distance from the player
      wrapped_bird_x = bird[:x]
      wrapped_bird_y = bird[:y]

      if (bird[:x] - @player[:x]).abs > @screen_width
        wrapped_bird_x = bird[:x] > @player[:x] ? bird[:x] - @maze_width * @maze_cell_w : bird[:x] + @maze_width * @maze_cell_w
      end

      if (bird[:y] - @player[:y]).abs > @screen_height
        wrapped_bird_y = bird[:y] > @player[:y] ? bird[:y] - @maze_height * @maze_cell_h : bird[:y] + @maze_height * @maze_cell_h
      end

      distance = Math.sqrt((wrapped_bird_x - @player[:x])**2 + (wrapped_bird_y - @player[:y])**2)
      distance > @screen_height * 2
    end

  end

  def draw_birds(ffi)
    return if @birds.empty?

    @birds.each do |bird|
      ffi.draw_sprite_5(x_to_screen(bird[:x]), # x
                        y_to_screen(bird[:y]), # y
                        bird[:w] * @camera[:zoom], # w
                        bird[:h] * @camera[:zoom], # h
                        "sprites/bird/frame-#{bird[:frame] + 1}.png", # path
                        bird[:angle], # angle
                        nil, # alpha
                        nil, # r
                        nil, # g,
                        nil, # b
                        nil, # tile_x
                        nil, # tile_y
                        nil, # tile_w
                        nil, # tile_h
                        false, # flip_horizontally
                        bird[:flip_vertically], # flip_vertically
                        nil, # angle_anchor_x
                        nil, # angle_anchor_y
                        nil, # source_x
                        nil, # source_y
                        nil, # source_w,
                        nil, # source_h
                        nil, # blendmode_enum
                        0.5, # anchor_x
                        0.5) # anchor_y


      # [Debug] draw path
      if @draw_bird_paths
        bird[:points].each do |l|
          x, y = l[0]
          x2, y2 = l[1]
          ffi.draw_line_2 x_to_screen(x), y_to_screen(y),
                          x_to_screen(x2),
                          y_to_screen(y2),
                          0, 0, 0, 255,
                          1
        end
      end

      # If the bird is within the wrapped viewport, draw it in its wrapped position
      if @wrapped_viewport
        map_w = @maze_width * @maze_cell_w
        wrapped_x = bird[:x] + (@wrapped_viewport[:position] == :left ? -map_w : map_w)

        ffi.draw_sprite_5(x_to_screen(wrapped_x), # x
                          y_to_screen(bird[:y]), # y
                          bird[:w] * @camera[:zoom], # w
                          bird[:h] * @camera[:zoom], # h
                          "sprites/bird/frame-#{bird[:frame] + 1}.png", # path
                          bird[:angle], # angle
                          nil, # alpha
                          nil, # r
                          nil, # g,
                          nil, # b
                          nil, # tile_x
                          nil, # tile_y
                          nil, # tile_w
                          nil, # tile_h
                          false, # flip_horizontally
                          bird[:flip_vertically], # flip_vertically
                          nil, # angle_anchor_x
                          nil, # angle_anchor_y
                          nil, # source_x
                          nil, # source_y
                          nil, # source_w,
                          nil, # source_h
                          nil, # blendmode_enum
                          0.5, # anchor_x
                          0.5) # anchor_y

        # [Debug] draw wrapped path
        if @draw_bird_paths
          bird[:points].each do |l|
            x, y = l[0]
            x2, y2 = l[1]
            wrapped_x1 = x + (@wrapped_viewport[:position] == :left ? -map_w : map_w)
            wrapped_x2 = x2 + (@wrapped_viewport[:position] == :left ? -map_w : map_w)

            ffi.draw_line_2 x_to_screen(wrapped_x1), y_to_screen(y),
                            x_to_screen(wrapped_x2), y_to_screen(y2),
                            0, 0, 0, 255, 1
          end
        end
      end
    end
  end

  def draw_player(ffi)
    player_sprite_index = 0.frame_index(count: 4, tick_count_override: @clock, hold_for: 10, repeat: true)

    ffi.draw_sprite_5(x_to_screen(@player[:x]), # x
                      y_to_screen(@player[:y]), # y
                      @player[:w] * @camera[:zoom], # w
                      @player[:h] * @camera[:zoom], # h
                      "sprites/balloon_#{player_sprite_index + 1}.png", # path
                      nil, # angle
                      nil, # alpha
                      nil, # r
                      nil, # g,
                      nil, # b
                      nil, # tile_x
                      nil, # tile_y
                      nil, # tile_w
                      nil, # tile_h
                      @player_flip, # flip_horizontally
                      nil, # flip_vertically
                      nil, # angle_anchor_x
                      nil, # angle_anchor_y
                      nil, # source_x
                      nil, # source_y
                      nil, # source_w,
                      nil, # source_h
                      nil, # blendmode_enum
                      0.5, # anchor_x
                      0.5) # anchor_y
  end

  def x_to_screen(x)
    ((x - @camera[:x]) * @camera[:zoom]) + @screen_width * 0.5
  end

  def y_to_screen(y)
    ((y - @camera[:y]) * @camera[:zoom]) + @screen_height * 0.5
  end

  def game_has_lost_focus?
    return true unless Kernel.tick_count > 0
    focus = !inputs.keyboard.has_focus

    if focus != @lost_focus
      if focus
        # putz "lost focus"
        audio[:music].paused = true
        audio[:wind].paused = true
      else
        # putz "gained focus"
        audio[:music].paused = false
        audio[:wind].paused = false
      end
    end
    @lost_focus = focus
  end

  def defaults
    return if @defaults_set

    @lost_focus = true
    @clock = 0
    @current_scene = :tick_title_scene
    @next_scene = nil
    @tile_x = nil
    @tile_y = nil
    @screen_height = 1280
    @screen_width = 720
    @wall_thickness = 48

    @player = {
      x: @wall_thickness * 2.0,
      y: @wall_thickness * 2.0,
      w: 120,
      h: 176,
      anchor_x: 0.5,
      anchor_y: 0.5,
      flip_horizontally: false,

      coins: 0,

      # Boost
      dx: 0.0,
      dy: 0.0,
      boost: 80.0,
      boosting: false,
      boost_remaining: 0,
      boost_duration: 120, # in ticks
      last_boost_time: -Float::INFINITY,

      # Physics
      vx: 0.0,
      vy: 0.0,
      speed: 2.0,
      rising: 0.1,
      damping: 0.95,
      max_speed: 10.0,
    }

    audio[:menu_music] = {
      input: 'sounds/InGameTheme20secGJ.ogg',
      gain: 0.8,
      paused: false,
      looping: true,
    }

    audio[:music] =
      {
      input: 'sounds/up-up-and-away-sketch.ogg',
      x: 0.0,
      y: 0.0,
      z: 0.0,
      gain: 0.7, # 0.1 is reasonably balanced
      paused: true,
      looping: true
    }

    audio[:wind] = {
      input: 'sounds/Wind.ogg',
      x: 0.0,
      y: 0.0,
      z: 0.0,
      gain: 0.0,
      paused: true,
      looping: true
    }

    # Create Maze
    @maze_cell_w = 400
    @maze_cell_h = 600
    @maze_width = 5
    @maze_height = 10
    create_maze

    # Create Minimap
    @minimap_cell_size = 16
    @minimap_width = @maze_width * @minimap_cell_size
    @minimap_height = @maze_height * @minimap_cell_size
    create_minimap

    # Create Camera
    @camera = {
      x: 0.0,
      y: 0.0,
      offset_x: 0.5,
      offset_y: 0.2,
      zoom: 1.0,
      zoom_speed: 0.05,
      lag: 0.05,
    }
    @camera_teleport_offset = { x: 0, y: 0 }

    # Create Background
    @bg_w, @bg_h = gtk.calcspritebox("sprites/cloudy_background.png")
    @bg_y = 0
    @bg_x = 0
    @bg_parallax = 0.3

    # Create Items
    create_coins
    create_items

    # Birds
    @birds = []
    @bird_spawn_interval = 100
    @bird_spawn_variance = 60

    # Configure wind
    @wind_gain_multiplier = 1.0
    @wind_gain_speed = 0.5

    # Configure clouds
    @cloud_bounciness = 0.75 # 0..1 representing energy loss on bounce

    @defaults_set = :true
  end
end

$gtk.reset
