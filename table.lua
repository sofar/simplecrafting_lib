crafting.table = {}
crafting.table.recipes = {}
crafting.table.recipes_by_output = {}

local recipes = crafting.table.recipes
local recipes_by_out = crafting.table.recipes_by_output

local function itemlist_to_countlist(inv)
	local count_list = {}
	for _,stack in ipairs(inv) do
		if not stack:is_empty() then
			local name = stack:get_name()
			count_list[name] = (count_list[name] or 0) + stack:get_count()
			-- If it is the most common item in a group, alias the group to it
			if minetest.registered_items[name] then
				for group,_ in pairs(minetest.registered_items[name].groups or {}) do
					if not count_list[group] 
					or (count_list[group] and count_list[count_list[group]] < count_list[name]) then
						count_list[group] = name
					end
				end
			end
		end
	end
	return count_list
end

local function get_craft_no(input_list,recipe)
	-- Recipe without groups (most common node in group instead)
	local work_recipe = {input={},output=table.copy(recipe.output)
		,ret=table.copy(recipe.ret)}
	local required_input = work_recipe.input
	for item,count in pairs(recipe.input) do
		if not input_list[item] then
			return 0
		end
		-- Groups are a string alias to most common member item
		if type(input_list[item]) == "string" then
			required_input[input_list[item]] 
				= (required_input[input_list[item]] or 0) + count
		else
			required_input[item] = (required_input[item] or 0) + count
		end
	end
	local no = math.huge
	for ingredient,count in pairs(required_input) do
		local max = input_list[ingredient] / count
		if max < 1 then
			return 0
		elseif max < no then
			no = max
		end
	end
	-- Return no of possible crafts as integer
	return math.floor(no),work_recipe
end


local function get_craftable_items(input_list)
	local craftable = {}
	local chosen = {}
	for i=1,#recipes do
		local no,recipe = get_craft_no(input_list,recipes[i])
		if no > 0 then
			for item,count in pairs(recipe.output) do
				if craftable[item] and count*no > craftable[item] then
					craftable[item] = count*no
					chosen[item] = recipe
				elseif not craftable[item] and count*no > 0 then
					craftable[#craftable+1] = item
					craftable[item] = count*no
					chosen[item] = recipe
				end
			end
		end
	end
	-- Limit stacks to stack limit
	for i=1,#craftable do
		local item = craftable[i]
		local count = craftable[item]
		local stack = ItemStack(item)
		local max = stack:get_stack_max()
		if count > max then
			count = max - max % chosen[item].output[item]
		end
		stack:set_count(count)
		craftable[i] = stack
		craftable[item] = nil
	end
	return craftable
end

local function refresh_output(inv)
	local itemlist = itemlist_to_countlist(inv:get_list("store"))
	local craftable = get_craftable_items(itemlist)
	inv:set_size("output",#craftable + ((8*6) - (#craftable%(8*6))))
	inv:set_list("output",craftable)
end

local function make_formspec(row,noitems)
	if noitems < (8*6) then
		row = 0
	elseif (row*8)+(8*6) > noitems then
		row = (noitems - (8*6)) / 8
	end

	local inventory = {
		"size[10.2,10.2]"
		, "list[context;store;0,0.5;2,5;]"
		, "list[context;output;2.2,0;8,6;" , tostring(row*8), "]"
		, "list[current_player;main;1.1,6.2;8,4;]"
		, "listring[context;output]"
		, "listring[current_player;main]"
		, "listring[context;store]"
		, "listring[current_player;main]"
	}
	if row >= 6 then
		inventory[#inventory+1] = "button[9.3,6.7;1,0.75;prev;«]"
	end
	if noitems > ((row/6)+1) * (8*6) then
		inventory[#inventory+1] = "button[9.1,6.2;1,0.75;next;»]"
	end
	inventory[#inventory+1] = "label[0,6.5;Row " .. tostring(row) .. "]"

	return table.concat(inventory),row
end

local function refresh_inv(meta)
	local inv = meta:get_inventory()
	refresh_output(inv)

	local page = meta:get_int("page")
	local form, page = make_formspec(page,inv:get_size("output"))
	meta:set_int("page",page)
	meta:set_string("formspec",form)
end

local function pay_items(inv,crafted,to_inv,to_list,player,no_crafted)
	local name = crafted:get_name()
	local no = no_crafted
	local itemlist = itemlist_to_countlist(inv:get_list("store"))
	local max = 0
	local craft_using

	-- Catch items in output without recipe (reported by cx384)
	if not recipes_by_out[name] then
		minetest.log("error","Item in table output list without recipe: "
			.. name)
		return
	end

	-- Get recipe which can craft the most
	for i=1,#recipes_by_out[name] do
		local out,recipe = get_craft_no(itemlist,recipes_by_out[name][i])
		if out > 0 and out * recipe.output[name] > max then
			max = out * recipe.output[name]
			craft_using = recipe
		end
	end

	-- Catch items in output without recipe (reported by cx384)
	if not craft_using then
		minetest.log("error","Item in table output list without valid recipe: "
			.. name)
		return
	end

	-- Increase amount taken if not a multiple of recipe output
	local output_factor = craft_using.output[name]
	if no % output_factor ~= 0 then
		no = no - (no % output_factor)
		if no + output_factor <= crafted:get_stack_max() then
			no = no + output_factor
		end
	end

	-- Take consumed items
	local input = craft_using.input
	local no_crafts = math.floor(no / output_factor)
	for item,count in pairs(input) do
		local to_remove = no_crafts * count
		local stack = ItemStack(item)
		stack:set_count(stack:get_stack_max())
		while to_remove > stack:get_stack_max() do
			inv:remove_item("store",stack)
			to_remove = to_remove - stack:get_stack_max()
		end

		if to_remove > 0 then
			stack:set_count(to_remove)
			inv:remove_item("store",stack)
		end
	end

	-- Add excess items
	local output = craft_using.output
	for item,count in pairs(output) do
		local to_add 
		if item == name then
			to_add = no - no_crafted
		else
			to_add = no_crafts * count
		end
		if no > 0 then
			local stack = ItemStack(item)
			local max = stack:get_stack_max()
			stack:set_count(max)
			while to_add > 0 do
				if to_add > max then
					to_add = to_add - max
				else
					stack:set_count(to_add)
					to_add = 0
				end
				local excess = to_inv:add_item(to_list,stack)
				if not excess:is_empty() then
					minetest.item_drop(excess,player,player:getpos())
				end
			end
		end
	end
	-- Add return items - copied code from above
	for item,count in pairs(craft_using.ret) do
		local to_add 
		to_add = no_crafts * count
		if no > 0 then
			local stack = ItemStack(item)
			local max = stack:get_stack_max()
			stack:set_count(max)
			while to_add > 0 do
				if to_add > max then
					to_add = to_add - max
				else
					stack:set_count(to_add)
					to_add = 0
				end
				local excess = to_inv:add_item(to_list,stack)
				if not excess:is_empty() then
					minetest.item_drop(excess,player,player:getpos())
				end
			end
		end
	end
end

crafting.table.register = function(def)
	def.ret = def.ret or {}
	-- Strip group: from group names to simplify comparison later
	for item,count in pairs(def.input) do
		local group = string.match(item,"^group:(%S+)$")
		if group then
			def.input[group] = count
			def.input[item] = nil
		end
	end
	recipes[#recipes+1] = def
	for item,_ in pairs(def.output) do
		recipes_by_out[item] = recipes_by_out[item] or {} 
		recipes_by_out[item][#recipes_by_out[item]+1] = def
	end
	return true
end

local function get_craftable_no(inv,stack)
	-- Re-calculate the no. items in the stack
	-- This is used in both fixes		
	local count = 0
	local no_per_out = 1
	local name = stack:get_name()
	for i=1,#recipes_by_out[name] do
		local out,recipe = get_craft_no(itemlist_to_countlist(inv:get_list("store")),recipes_by_out[name][i])
		if out > 0 and out * recipe.output[name] > count then
			count = out * recipe.output[name]
			no_per_out = recipe.output[name]
		end
	end
	-- Stack limit correction
	local max = stack:get_stack_max()
	if max < count then
		count = max - (max % no_per_out)
	end

	return count
end

local function count_fixes(inv,stack,new_stack,tinv,tlist,player)
	

	if (not new_stack:is_empty() 
	and new_stack:get_name() ~= stack:get_name())
	-- Only effective if stack limits are ignored by table
	-- Stops below fix being triggered incorrectly when swapping
	or new_stack:get_count() == new_stack:get_stack_max() then
		local excess = tinv:add_item(tlist,new_stack)
		if not excess:is_empty() then
			minetest.item_drop(excess,player,player:getpos())
		end

		-- Delay re-calculation until items are back in input inv
		local count = get_craftable_no(inv,stack)

		-- Whole stack has been taken - calculate how many
		return count,true
	end

	-- Delay re-calculation as condition above may cause items to not be
	-- in the correct inv
	local count = get_craftable_no(inv,stack)

	-- Fix for listring movement causing multiple updates with
	-- incorrect values when trying to move items onto a stack and
	-- exceeding stack max
	-- A second update then tries to move the remaining items
	if (not new_stack:is_empty()
	and new_stack:get_name() == stack:get_name()
	and new_stack:get_count() + stack:get_count() > count) then
		return stack:get_count() - new_stack:get_count(),false
	end
end
		
minetest.register_node("crafting:table",{
	description = "Crafting Table",
	drawtype = "normal",
	tiles = {"crafting.table_top.png","default_chest_top.png"
		,"crafting.table_front.png","crafting.table_front.png"
		,"crafting.table_side.png","crafting.table_side.png"},
	paramtype2 = "facedir",
	is_ground_content = false,
	groups = {oddly_breakable_by_hand = 1,choppy=3},
	on_construct = function(pos)
		local meta = minetest.get_meta(pos)
		local inv = meta:get_inventory()
		inv:set_size("store", 2*5)
		inv:set_size("output", 8*6)
		meta:set_int("row",0)
		meta:set_string("formspec",make_formspec(0,0))
	end,
	allow_metadata_inventory_move = function(pos,flist,fi,tlist,ti,no,player)
		if tlist == "output" then
			return 0
		end
		return no
	end,
	allow_metadata_inventory_put = function(pos,lname,i,stack,player)
		if lname == "output" then
			return 0
		end
		return stack:get_count()
	end,
	on_metadata_inventory_move = function(pos,flist,fi,tlist,ti,no,player)
		local meta = minetest.get_meta(pos)
		if flist == "output" and tlist == "store" then
			local inv = meta:get_inventory()

			local stack = inv:get_stack(tlist,ti)
			local new_stack = inv:get_stack(flist,fi)
			-- Set count to no, for the use of count_fixes
			stack:set_count(no)
			local count,refresh = count_fixes(inv,stack,new_stack,inv
				,"store",player)

			if not count then
				count = no
				refresh = true
			end

			pay_items(inv,stack,inv,"store",player,count)

			if refresh then
				refresh_inv(meta)
			end
			return
		end
		refresh_inv(meta)
	end,
	on_metadata_inventory_take = function(pos,lname,i,stack,player)
		local meta = minetest.get_meta(pos)
		if lname == "output" then
			local inv = meta:get_inventory()
			local new_stack = inv:get_stack(lname,i)
			local count,refresh = count_fixes(inv,stack,new_stack
				,player:get_inventory(),"main",player) 

			if not count then
				count = stack:get_count()
				refresh = true
			end

			pay_items(inv,stack,player:get_inventory(),"main",player,count)

			if refresh then
				refresh_inv(meta)
			end
			return
		end
		refresh_inv(meta)
	end,
	on_metadata_inventory_put = function(pos,lname,i,stack,player)
		local meta = minetest.get_meta(pos)
		refresh_inv(meta)
	end,
	on_receive_fields = function(pos,formname,fields,sender)
		local meta = minetest.get_meta(pos)
		local inv = meta:get_inventory()
		local size = inv:get_size("output")
		local row = meta:get_int("row")
		if fields.next then
			row = row + 6
		elseif fields.prev  then
			row = row - 6
		else
			return
		end
		local form, row = make_formspec(row,size)
		meta:set_int("row",row)
		meta:set_string("formspec",form)
	end,
	can_dig = function(pos,player)
		local meta = minetest.get_meta(pos)
		local inv = meta:get_inventory()
		return inv:is_empty("store")
	end,
	--allow_metadata_inventory_take = function(pos,lname,i,stack,player) end,
})
