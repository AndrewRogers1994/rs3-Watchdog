local InventoryViewer = {}

---@param ctx LibNodeGraph.RunContext
local function run(ctx)
    ctx.state.snapshot = ctx:In("snapshot")
end

---@param registry LibNodeGraph.Registry
function InventoryViewer.Register(registry)
    registry:RegisterNodeType("inventory.viewer", {
        category = "inventory",
        displayName = "Inventory Viewer",
        description = "Debugger: latches a Snapshot and shows it as a 4x7 item grid on the node",
        pins = {
            { name = "in", kind = "exec", direction = "in" },
            { name = "snapshot", kind = "data", direction = "in", dataType = "invSnapshot",
              label = "Snapshot" },
        },
        run = run,
    })
end

return InventoryViewer
