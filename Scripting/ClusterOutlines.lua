-- Monotone Chain Algorithm for Convex Hull
-- Optimized: Uses shared buffer to avoid allocs
local function getConvexHull(particles: {Particle}, buffer: {Particle}): {Particle}
    local n = #particles
    if n == 0 then return {} end
    if n <= 2 then return particles end

    -- Optimization: Use shared buffer
    local pts = buffer
    for i = 1, n do pts[i] = particles[i] end
    -- Clear rest of buffer
    for i = n + 1, #pts do pts[i] = nil end

    table_sort(pts, function(a: Particle, b: Particle)
        return a.x < b.x or (a.x == b.x and a.y < b.y)
    end)

    local hull: {Particle} = {}
    -- Lower hull
    for i = 1, n do
        local p = pts[i]
        while #hull >= 2 and cross(hull[#hull-1], hull[#hull], p) <= 0 do
            table.remove(hull)
        end
        table_insert(hull, p)
    end

    -- Upper hull
    local lowerLen = #hull
    for i = n-1, 1, -1 do
        local p = pts[i]
        while #hull > lowerLen and cross(hull[#hull-1], hull[#hull], p) <= 0 do
            table.remove(hull)
        end
        table_insert(hull, p)
    end

    table.remove(hull)
    return hull
end

local function drawClusterOutlines(self: ParticleSystemNode, renderer: Renderer)
    local parts = self._particles
    if not parts then return end
    
    -- Optimization: Use cached clusters
    local clusters = self.groupedClusters
    local buffer = self.sortBuffer
    
    local path = self.clusterPath
    path:reset()
    
    for cid, cluster in pairs(clusters) do
        if #cluster > 0 then
            local hull = getConvexHull(cluster, buffer)
            local count = #hull
            
            if count > 0 then
                -- 1. Ensure CW winding (Positive area in Y-down coordinates)
                local area = getSignedArea(hull)
                if area < 0 then
                    -- Reverse to make it CW
                    local rev: {Particle} = {}
                    for i = count, 1, -1 do table_insert(rev, hull[i]) end
                    hull = rev
                end
                
                -- 2. Trace Offset Hull
                for i = 1, count do
                    local curr = hull[i]
                    local nextP = hull[(i % count) + 1]
                    local prevP = hull[((i - 2 + count) % count) + 1]
                    
                    -- Vector to next
                    local dx = nextP.x - curr.x
                    local dy = nextP.y - curr.y
                    local len = msqrt(dx*dx + dy*dy)
                    if len < 0.001 then len = 1 end
                    
                    -- Normal pointing out (for CW hull in Y-down: (dy, -dx))
                    local nx = dy / len
                    local ny = -dx / len
                    
                    -- Vector from prev matches prev segment
                    local pdx = curr.x - prevP.x
                    local pdy = curr.y - prevP.y
                    local plen = msqrt(pdx*pdx + pdy*pdy)
                    if plen < 0.001 then plen = 1 end
                    
                    -- Normal of previous segment
                    local pnx = pdy / plen
                    local pny = -pdx / plen
                    
                    local r = curr.radius + self.outlineExpansion
                    
                    -- Start of arc at this vertex (end of incoming edge's offset)
                    local arcStart = Vector.xy(curr.x + pnx * r, curr.y + pny * r)
                    
                    -- End of arc at this vertex (start of outgoing edge's offset)
                    local arcEnd = Vector.xy(curr.x + nx * r, curr.y + ny * r)
                    
                    -- Angles for arc interpolation
                    local startAng = matan2(pny, pnx)
                    local endAng = matan2(ny, nx)
                    
                    -- Resolve angle wrapping
                    local diff = endAng - startAng
                    while diff <= -math.pi do diff = diff + 2*math.pi end
                    while diff > math.pi do diff = diff - 2*math.pi end
                    
                    if i == 1 then
                        path:moveTo(arcStart)
                    else
                        path:lineTo(arcStart)
                    end
                    
                    -- Approximate Arc with line segments
                    local steps = mfloor(mabs(diff) / 0.15) + 1
                    local step = diff / steps
                    for s = 1, steps do
                        local a = startAng + step * s
                        path:lineTo(Vector.xy(curr.x + mcos(a) * r, curr.y + msin(a) * r))
                    end
                end
                path:close()
            end
        end
    end
    
    if renderer then
        renderer:drawPath(path, self.clusterFillPaint)
        renderer:drawPath(path, self.clusterPaint)
    end
end

drawClusterOutlines(self, renderer)