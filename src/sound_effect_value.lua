-- What a Sound Effect Control stores after the player acts. Callers pass the
-- current stored value and what the player did. This module does not read the
-- Pack registry, does not draw, and does not call Packs.live().

local SoundEffectValue = {}

--- A stored pack sound effect: Pack name, author id, and builtin sound id.
---@param value any
---@return boolean
function SoundEffectValue.isPackSoundEffect(value)
    return type(value) == "table"
        and type(value.pack) == "string"
        and type(value.authorId) == "string"
        and type(value.soundId) == "number"
end

--- The builtin sound id already stored, when the value is a number or a pack
--- sound effect. Anything else has none.
---@param stored any
---@return number|nil
local function storedSoundId(stored)
    if type(stored) == "number" then return stored end
    if SoundEffectValue.isPackSoundEffect(stored) then return stored.soundId end
    return nil
end

--- The value to store after the player acts.
--- "row" copies that row and does not consult the live registry.
--- "number" is a typed builtin sound id with the pack list left untouched:
--- the same id keeps the stored value, including an outdated pack sound effect,
--- and a different id stores only that number.
--- "none" stores the typed number and drops a pack sound effect, even when
--- that number is the one the record already holds.
--- "highlight" and "dismiss" leave the stored value unchanged.
---@param stored any
---@param action "row"|"number"|"none"|"highlight"|"dismiss"
---@param choice any
---@return any
function SoundEffectValue.apply(stored, action, choice)
    if action == "highlight" or action == "dismiss" then
        return stored
    end
    if action == "row" and SoundEffectValue.isPackSoundEffect(choice) then
        return { pack = choice.pack, authorId = choice.authorId, soundId = choice.soundId }
    end
    if action == "none" and type(choice) == "number" then
        return choice
    end
    if action == "number" and type(choice) == "number" then
        local current = storedSoundId(stored)
        if current ~= nil and choice == current then return stored end
        return choice
    end
    return stored
end

return SoundEffectValue
