AddCSLuaFile( "cl_init.lua" )
AddCSLuaFile( "shared.lua" )

include( "shared.lua" )

DEFINE_BASECLASS( "base_glide_aircraft" )

--- Override this base class function.
function ENT:OnPostInitialize()
    BaseClass.OnPostInitialize( self )

    -- Setup variables used on all helicopters
    self.rotors = {}
end

--- Override this base class function.
function ENT:PhysicsCollide( data )
    if self:GetOutOfControl() then
        local ent = data.HitEntity
        local isPlayer = IsValid( ent ) and ent:IsPlayer()

        if not isPlayer then
            self:Explode()
            return
        end
    end

    BaseClass.PhysicsCollide( self, data )
end

--- Override this base class function.
function ENT:Repair()
    BaseClass.Repair( self )

    self:SetOutOfControl( false )

    -- Create main rotor, if it doesn't exist
    if not IsValid( self.mainRotor ) then
        self.mainRotor = self:CreateRotor( self.MainRotorOffset, self.MainRotorRadius, self.MainRotorModel, self.MainRotorFastModel )
        self.mainRotor:SetBaseAngles( self.MainRotorAngle )
    end

    -- Create tail rotor, if it doesn't exist and we have a model for it 
    if not IsValid( self.tailRotor ) then
        self.tailRotor = self:CreateRotor( self.TailRotorOffset, self.TailRotorRadius, self.TailRotorModel, self.TailRotorFastModel )
        self.tailRotor:SetBaseAngles( self.TailRotorAngle )
        self.tailRotor:SetSpinAxis( "Right" )
    end

    local validRotors = {}
    local validCount = 0

    for _, rotor in ipairs( self.rotors ) do
        if IsValid( rotor ) then
            rotor:Repair()

            validCount = validCount + 1
            validRotors[validCount] = rotor
        end
    end

    self.rotors = validRotors
end

--- Creates and stores a new rotor entity.
---
--- `radius` is used for collision checking.
--- `slowModel` is the model shown when the rotor is spinning slowly.
--- `fastModel` is the model shown when the rotor is spinning fast.
function ENT:CreateRotor( offset, radius, slowModel, fastModel )
    local rotor = ents.Create( "glide_rotor" )

    if not rotor or not IsValid( rotor ) then
        self:Remove()
        error( "Failed to spawn rotor! Vehicle removed!" )
        return
    end

    self:DeleteOnRemove( rotor )

    rotor:SetParent( self )
    rotor:SetLocalPos( offset )
    rotor:Spawn()
    rotor:SetupRotor( offset, radius, slowModel, fastModel )

    self.rotors[#self.rotors + 1] = rotor

    return rotor
end

--- Override this base class function.
function ENT:TurnOn()
    BaseClass.TurnOn( self )
    self:SetOutOfControl( false )
end

--- Implement this base class function.
function ENT:OnDriverEnter()
    if self:GetEngineHealth() > 0 then
        self:TurnOn()
    end
end

--- Implement this base class function.
function ENT:OnDriverExit()
    if self.altitude > 400 and self:GetPower() > 0.2 then
        self:SetOutOfControl( true )
    else
        self:TurnOff()
    end
end

local IsValid = IsValid
local Approach = math.Approach
local ExpDecay = Glide.ExpDecay
local TriggerOutput = WireLib and WireLib.TriggerOutput or nil

--- Override this base class function.
function ENT:OnPostThink( dt, selfTbl )
    BaseClass.OnPostThink( self, dt, selfTbl )

    if selfTbl.inputFlyMode == 0 then -- Glide.MOUSE_FLY_MODE.AIM
        selfTbl.inputPitch = self:GetInputFloat( 1, "pitch" )
        selfTbl.inputRoll = ExpDecay( selfTbl.inputRoll, self:GetInputFloat( 1, "roll" ), 6, dt )
        selfTbl.inputYaw = self:GetInputFloat( 1, "yaw" )
    else
        selfTbl.inputPitch = ExpDecay( selfTbl.inputPitch, self:GetInputFloat( 1, "pitch" ), 6, dt )
        selfTbl.inputRoll = ExpDecay( selfTbl.inputRoll, self:GetInputFloat( 1, "roll" ), 6, dt )
        selfTbl.inputYaw = ExpDecay( selfTbl.inputYaw, self:GetInputFloat( 1, "yaw" ), 6, dt )
    end

    local power = self:GetPower()
    local throttle = self:GetInputFloat( 1, "throttle" )

    -- If the main rotor was destroyed, turn off and disable power
    if not IsValid( selfTbl.mainRotor ) then
        if self:IsEngineOn() then
            self:TurnOff()
        end

        power = 0
    end

    if self:IsEngineOn() then
        -- Make sure the physics stay awake,
        -- otherwise the driver's input won't do anything.
        local phys = self:GetPhysicsObject()

        if IsValid( phys ) and phys:IsAsleep() then
            phys:Wake()
        end

        if self:GetEngineHealth() > 0 then
            -- Approach towards the idle power plus the offset
            local powerOffset = throttle * 0.2

            -- If no throttle input and low on the ground, decrease power
            if selfTbl.altitude < 25 and throttle < 0.1 then
                powerOffset = powerOffset - 0.1
            end

            power = Approach( power, 1 + powerOffset, dt * selfTbl.powerResponse )

        elseif selfTbl.altitude > 20 then
            -- Fake auto-rotation
            power = Approach( power, 0.6, dt * 0.1 )
        else
            -- Turn off
            power = Approach( power, 0, dt * selfTbl.powerResponse * 0.5 )

            if power < 0.1 then
                self:TurnOff()
            end
        end

        self:SetPower( power )

        -- Process damage effects over time
        self:DamageThink( dt )
    else
        -- Approach towards 0 power
        power = ( power > 0 ) and ( power - dt * selfTbl.powerResponse * 0.5 ) or 0
        self:SetPower( power )
    end

    -- Spin the rotors
    for _, rotor in ipairs( selfTbl.rotors ) do
        if IsValid( rotor ) then
            rotor.spinMultiplier = power
        end
    end

    -- Handle out-of-control state
    if self:IsEngineOn() then
        local isOutOfControl = self:GetOutOfControl()

        if isOutOfControl then
            local phys = self:GetPhysicsObject()
            local force = self:GetRight() * power * phys:GetMass() * -100

            phys:ApplyForceOffset( force * dt, self:LocalToWorld( selfTbl.TailRotorOffset ) )

        elseif power > 0.5 and not IsValid( selfTbl.tailRotor ) and selfTbl.TailRotorModel then
            self:SetOutOfControl( true )
        end
    end

    if TriggerOutput then
        TriggerOutput( self, "Power", power )
    end
end

local Clamp = math.Clamp

--- Implement this base class function.
function ENT:OnSimulatePhysics( phys, _, outLin, outAng )
    local params = self.HelicopterParams
    local power = Clamp( params.basePower + self:GetPower(), 0, 1 )

    if power > 0.1 then
        local effectiveness = Clamp( power, 0, self:GetOutOfControl() and 0.5 or 1 )
        self:SimulateHelicopter( phys, params, effectiveness, outLin, outAng )
    end
end
