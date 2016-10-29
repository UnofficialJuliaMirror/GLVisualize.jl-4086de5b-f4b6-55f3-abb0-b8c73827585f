
type TextureAtlas
    rectangle_packer::RectanglePacker
    mapping         ::Dict{Any, Int} # styled glyph to index in sprite_attributes
    index           ::Int
    images          ::Texture{Float16, 2}
    attributes      ::Vector{Vec4f0}
    scale           ::Vector{Vec2f0}
    extent          ::Vector{FontExtent{Float64}}


end
function TextureAtlas(initial_size=(4096, 4096))
    images = Texture(fill(Float16(0.0), initial_size...), minfilter=:linear, magfilter=:linear)
    TextureAtlas(
        RectanglePacker(SimpleRectangle(0, 0, initial_size...)),
        Dict{Any, Int}(),
        1,
        images,
        Vec4f0[],
        Vec2f0[],
        FontExtent{Float64}[]
    )
end

begin #basically a singleton for the textureatlas

    const local _atlas_cache = Dict{WeakRef, TextureAtlas}()
    const local _cache_path = joinpath(dirname(@__FILE__), "..", ".cache", "texture_atlas.jls")
    const local _default_font = Vector{Ptr{FreeType.FT_FaceRec}}[]
    const local _alternative_fonts = Vector{Ptr{FreeType.FT_FaceRec}}[]

    function defaultfont()
        if isempty(_default_font)
            push!(_default_font, newface(assetpath("fonts", "DejaVuSans.ttf")))
        end
        _default_font[]
    end
    function alternativefonts()
        if isempty(_alternative_fonts)
            alternatives = [
                "DejaVuSans.ttf",
                "NotoSansCJKkr-Regular.otf",
                "NotoSansCuneiform-Regular.ttf",
                "NotoSansSymbols-Regular.ttf",
                "FiraMono-Medium.ttf"
            ]
            for font in alternatives
                push!(_alternative_fonts, newface(assetpath("fonts", font)))
            end
        end
        _alternative_fonts
    end

    function cached_load()
        if isfile(_cache_path)
            return open(_cache_path) do io
                dict = deserialize(io)
                dict[:images] = Texture(dict[:images]) # upload to GPU
                fields = [dict[n] for n in fieldnames(TextureAtlas)]
                TextureAtlas(fields...)
            end
        else
            atlas = TextureAtlas()
            for c in '\u0000':'\u00ff' #make sure all ascii is mapped linearly
                insert_glyph!(atlas, c, defaultfont())
            end
            to_cache(atlas) # cache it
            return atlas
        end
    end

    function to_cache(atlas)
        if !ispath(dirname(_cache_path))
            mkdir(dirname(_cache_path))
        end
        open(_cache_path, "w") do io
            dict = Dict(
                n => getfield(atlas, n) for n in fieldnames(atlas)
            )
            dict[:images] = gpu_data(dict[:images])
            serialize(io, dict)
        end
    end

    function get_texture_atlas(window=current_screen())
        root = WeakRef(GLWindow.rootscreen(window))
        # remove dead bodies
        filter!((k, v)-> _is_alive(k), _atlas_cache)
        get!(_atlas_cache, root) do
            cached_load() # initialize only on demand
        end
    end

end

function glyph_index!(atlas::TextureAtlas, c::Char, font)
    if FT_Get_Char_Index(font[], c) == 0
        for afont in alternativefonts()
            if FT_Get_Char_Index(afont[], c) != 0
                font = afont
            end
        end
    end
    if c < '\u00ff' && font == defaultfont() # characters up to '\u00ff'(255), are directly mapped for default font
        Int(c)+1
    else #others must be looked up, since they're inserted when used first
        return insert_glyph!(atlas, c, font)
    end
end

glyph_scale!(c::Char) = glyph_scale!(get_texture_atlas(), c, defaultfont())
glyph_uv_width!(c::Char) = glyph_uv_width!(get_texture_atlas(), c, defaultfont())

function glyph_uv_width!(atlas::TextureAtlas, c::Char, font)
    atlas.attributes[glyph_index!(atlas, c, font)]
end
function glyph_scale!(atlas::TextureAtlas, c::Char, font)
    atlas.scale[glyph_index!(atlas, c, font)]
end
function glyph_extent!(atlas::TextureAtlas, c::Char, font)
    atlas.extent[glyph_index!(atlas, c, font)]
end

function bearing(extent)
     Point2f0(extent.horizontal_bearing[1], -(extent.scale[2]-extent.horizontal_bearing[2]))
end
function glyph_bearing!{T}(atlas::TextureAtlas, c::Char, font, scale::T)
    T(bearing(atlas.extent[glyph_index!(atlas, c, font)])) .* scale
end
function glyph_advance!{T}(atlas::TextureAtlas, c::Char, font, scale::T)
    T(atlas.extent[glyph_index!(atlas, c, font)].advance) .* scale
end


insert_glyph!(atlas::TextureAtlas, glyph::Char, font) = get!(atlas.mapping, (glyph, font)) do
    uv, rect, extent, width_nopadd = render(atlas, glyph, font)
    tex_size       = Vec2f0(size(atlas.images))
    uv_start       = Vec2f0(uv.x, uv.y)
    uv_width       = Vec2f0(uv.w, uv.h)
    real_heightpx  = width_nopadd[2]
    halfpadding    = (uv_width - width_nopadd) / 2f0
    real_start     = uv_start + halfpadding # include padding
    relative_start = real_start ./ tex_size # use normalized texture coordinates
    relative_width = (real_start+width_nopadd) ./ tex_size

    uv_offset_width = Vec4f0(relative_start..., relative_width...)
    i               = atlas.index
    push!(atlas.attributes, uv_offset_width)
    push!(atlas.scale, Vec2f0(width_nopadd))
    push!(atlas.extent, extent)
    atlas.index = i+1
    return i
end

function sdistancefield(img, restrict_steps=2)
    w, h = size(img)
    w1, h1 = w, h

    halfpad = 24*(2^restrict_steps) # padd so that after restrict it comes out as roughly 48 pixel
    w, h = w+2halfpad, h+2halfpad #pad this, to avoid cuttoffs
    in_or_out = Bool[begin
        x, y = i-halfpad, j-halfpad
        if checkbounds(Bool, img, x,y)
            img[x,y] >= 1.0
        else
            false
        end
    end for i=1:w, j=1:h]

    sd = sdf(in_or_out)
    for i=1:restrict_steps
        w1, h1 = Images.restrict_size(w1), Images.restrict_size(h1)
        sd = Images.restrict(sd) #downsample
    end
    sz = Vec2f0(size(img))
    maxlen = norm(sz)
    sw, sh = size(sd)

    Float16[clamp(sd[i,j]/maxlen, -1, 1) for i=1:sw, j=1:sh], Vec2f0(w1, h1), (2^restrict_steps)
end

function GLAbstraction.render(atlas::TextureAtlas, glyph::Char, font)
    #select_font_face(cc, font)
    if glyph == '\n' # don't render  newline
        glyph = ' '
    end
    bitmap, extent = renderface(font, glyph, (164, 164))
    restrict_steps=2
    sd, width_nopadd, scaling_factor = sdistancefield(bitmap, restrict_steps)
    extent = extent ./ Vec2f0(2^restrict_steps)
    rect = SimpleRectangle(0, 0, size(sd)...)
    uv   = push!(atlas.rectangle_packer, rect) #find out where to place the rectangle
    uv == nothing && error("texture atlas is too small. Resizing not implemented yet. Please file an issue at GLVisualize if you encounter this") #TODO resize surface
    atlas.images[uv.area] = sd
    uv.area, rect, extent, width_nopadd
end
