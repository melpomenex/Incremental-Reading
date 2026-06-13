local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local OverlapGroup = require("ui/widget/overlapgroup")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local TitleBar = require("ui/widget/titlebar")
local TextBoxWidget = require("ui/widget/textboxwidget")
local ButtonTable = require("ui/widget/buttontable")
local TextWidget = require("ui/widget/textwidget")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Geom = require("ui/geometry")
local Screen = require("device").screen
local Device = require("device")
local Font = require("ui/font")
local Size = require("ui/size")
local GestureRange = require("ui/gesturerange")
local Blitbuffer = require("ffi/blitbuffer")
local _ = require("gettext")
local T = require("ffi/util").template

local db = require("database")
local SM20Engine = require("srs_engine")

-- Defensive requires: if any of these widgets are absent on an older/newer
-- KOReader build, the plugin must still load. Each is checked before use.
local has_progresswidget, ProgressWidget = pcall(require, "ui/widget/progresswidget")
local has_keyvaluepage,  KeyValuePage  = pcall(require, "ui/widget/keyvaluepage")
local has_inputdialog,   InputDialog   = pcall(require, "ui/widget/inputdialog")

-- Border colors for the four grade buttons. ColorRGB32 is tried first
-- (color screens); if it's unavailable or errors we fall back to distinct
-- grayscale constants so e-ink devices still get visual hierarchy.
local function gradeColor(r, g, b, fallback)
    if Blitbuffer and Blitbuffer.ColorRGB32 then
        local ok, color = pcall(Blitbuffer.ColorRGB32, r, g, b, 0xFF)
        if ok and color then return color end
    end
    return fallback
end

local GRADE_COLORS = {
    again = gradeColor(0x8B, 0x2C, 0x2C, Blitbuffer.COLOR_BLACK),     -- dark red
    hard  = gradeColor(0x8B, 0x5A, 0x2C, Blitbuffer.COLOR_DARK_GRAY), -- amber
    good  = gradeColor(0x2C, 0x5A, 0x8B, Blitbuffer.COLOR_GRAY),      -- blue
    easy  = gradeColor(0x2C, 0x7A, 0x4E, Blitbuffer.COLOR_LIGHT_GRAY),-- green
}

local GRADE_LABELS = {
    again = _("Again"),
    hard  = _("Hard"),
    good  = _("Good"),
    easy  = _("Easy"),
}

local function hasCloze(text)
    if not text then return false end
    return text:find("{{.-}}") ~= nil
end

local function hideCloze(text)
    if not text then return "" end
    return text:gsub("{{(.-)}}", function(match)
        local inner = match:match("^%d+::(.*)$") or match
        return "[...]"
    end)
end

local function revealCloze(text)
    if not text then return "" end
    return text:gsub("{{(.-)}}", function(match)
        local inner = match:match("^%d+::(.*)$") or match
        return "== " .. inner .. " =="
    end)
end

local QueueView = InputContainer:extend{
    covers_fullscreen = true,
}

function QueueView:init()
    self.dimen = Geom:new{
        x = 0,
        y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }

    self.current_idx = 1
    self.cloze_revealed = false
    self.cards = self.cards or {}
    self.total_cards = #self.cards
    self.reviewed_count = 0
    self.pending_reviews = {}
    self.prev_cards = {}
    self.grade_counts = { again = 0, hard = 0, good = 0, easy = 0 }

    self.interval_matrix, self.count_matrix = db:loadIntervalMatrix()

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.NextCard = { { Device.input.group.PgFwd } }
        self.key_events.PrevCard = { { Device.input.group.PgBack } }
    end

    if Device:isTouchDevice() then
        self.ges_events.Swipe = {
            GestureRange:new{ ges = "swipe", range = self.dimen }
        }
    end

    self:_buildUI()
end

-- Read-only SM-20 preview for each grade. Used to label buttons with the
-- predicted next interval ("Again (1d)", "Good (3d)", etc).
function QueueView:_computePreviews(card)
    local out = {}
    for _, grade in ipairs({ "again", "hard", "good", "easy" }) do
        local ok, result = pcall(function()
            return SM20Engine:preview(card, grade, self.interval_matrix, self.count_matrix)
        end)
        if ok and result then
            out[grade] = SM20Engine.formatInterval(result.next_review_offset_days)
        else
            out[grade] = "?"
        end
    end
    return out
end

function QueueView:_buildUI()
    local card = self.cards[self.current_idx]
    if not card then
        self[1] = FrameContainer:new{
            height = self.dimen.h,
            padding = 0,
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = self.dimen,
                VerticalGroup:new{
                    align = "center",
                    TextWidget:new{
                        text = _("No cards due for review"),
                        face = Font:getFace("infofont"),
                    },
                },
            },
        }
        return
    end

    -- 1. Title bar with chapter subtitle and back-arrow to source
    self.title_bar = TitleBar:new{
        width = self.dimen.w,
        title = card.book_title or "",
        subtitle = (card.chapter and card.chapter ~= "") and card.chapter or nil,
        close_callback = function()
            self:onClose()
        end,
        show_parent = self,
        left_icon = "appbar.navigation.back",
        left_icon_tap_callback = function()
            self:onGoToSource()
        end,
        left_icon_hold_callback = false,
    }

    -- 2. Progress bar (skipped if ProgressWidget is unavailable on this build)
    local pct = self.total_cards > 0 and (self.reviewed_count / self.total_cards) or 0
    if has_progresswidget then
        self.progress_bar = ProgressWidget:new{
            width = self.dimen.w - Size.padding.fullscreen * 2,
            height = Size.padding.default,
            percentage = pct,
            margin_h = 0,
            margin_v = Size.padding.small,
            radius = 0,
        }
    else
        self.progress_bar = TextWidget:new{
            text = string.rep("=", math.floor(pct * 20)) .. string.rep(" ", 20 - math.floor(pct * 20)),
            face = Font:getFace("smallinfofont"),
        }
    end

    -- 3. Progress text + percentage
    local pct_text = string.format("%d%%", math.floor(pct * 100 + 0.5))
    self.progress_widget = TextWidget:new{
        text = T(_("Reviewed %1 / %2  ·  %3"), self.reviewed_count, self.total_cards, pct_text),
        face = Font:getFace("smallinfofont"),
        fgcolor = Blitbuffer.COLOR_GRAY_6,
    }

    -- 4. Card metadata subtitle (reps / interval / difficulty)
    local interval_label = SM20Engine.formatInterval(card.stability)
    local diff_pct = math.floor((card.difficulty or 0.5) * 100 + 0.5)
    self.meta_widget = TextWidget:new{
        text = T(_("Reps: %1  ·  Interval: %2  ·  Diff: %3%%"),
            tostring(card.repetition or 1), interval_label, tostring(diff_pct)),
        face = Font:getFace("smallinfofont"),
        fgcolor = Blitbuffer.COLOR_GRAY_6,
    }

    -- 5. Card text widget
    local card_text = card.text or ""
    local card_has_cloze = hasCloze(card_text)
    local text_to_display = card_text
    if card_has_cloze then
        text_to_display = self.cloze_revealed and revealCloze(card_text) or hideCloze(card_text)
    end

    -- 6. Buttons — grade row gets predicted intervals + colors; Edit on its own row
    local bottom_buttons
    if card_has_cloze and not self.cloze_revealed then
        bottom_buttons = {
            {
                {
                    text = _("Show Answer"),
                    callback = function()
                        self.cloze_revealed = true
                        self:_buildUI()
                        UIManager:setDirty(self, "full")
                    end,
                },
            },
            {
                {
                    text = _("Edit"),
                    callback = function()
                        self:onEditCard()
                    end,
                },
            },
        }
    else
        local preview = self:_computePreviews(card)
        bottom_buttons = {
            {
                {
                    text = T(_("%1 (%2)"), GRADE_LABELS.again, preview.again),
                    callback = function() self:onGrade("again") end,
                    color = GRADE_COLORS.again,
                },
                {
                    text = T(_("%1 (%2)"), GRADE_LABELS.hard, preview.hard),
                    callback = function() self:onGrade("hard") end,
                    color = GRADE_COLORS.hard,
                },
                {
                    text = T(_("%1 (%2)"), GRADE_LABELS.good, preview.good),
                    callback = function() self:onGrade("good") end,
                    color = GRADE_COLORS.good,
                },
                {
                    text = T(_("%1 (%2)"), GRADE_LABELS.easy, preview.easy),
                    callback = function() self:onGrade("easy") end,
                    color = GRADE_COLORS.easy,
                },
            },
            {
                {
                    text = _("Edit"),
                    callback = function()
                        self:onEditCard()
                    end,
                },
            },
        }
    end

    local button_table = ButtonTable:new{
        width = self.dimen.w,
        buttons = bottom_buttons,
        show_parent = self,
    }

    -- 7. Compute text-widget height from sibling widget heights (not magic numbers)
    local used_h = self.title_bar:getHeight()
        + (self.progress_bar:getSize().h or 0)
        + (self.progress_widget:getSize().h or 0)
        + (self.meta_widget:getSize().h or 0)
        + (button_table:getSize().h or 0)
        + Size.padding.default * 4
    local content_height = math.max(Size.item.height_default * 3, self.dimen.h - used_h)

    self.text_widget = TextBoxWidget:new{
        text = text_to_display,
        face = Font:getFace("infofont"),
        width = self.dimen.w - Size.padding.fullscreen * 2,
        height = content_height,
        scroll = true,
        scroll_bar_width = Size.padding.small,
        dialog = self,
    }

    -- 8. Layout: title/progress/text/meta stacked at top, buttons pinned to bottom
    local content = VerticalGroup:new{
        align = "center",
        self.title_bar,
        self.progress_bar,
        self.progress_widget,
        self.text_widget,
        self.meta_widget,
    }

    self[1] = FrameContainer:new{
        height = self.dimen.h,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        OverlapGroup:new{
            dimen = self.dimen,
            content,
            BottomContainer:new{
                dimen = self.dimen,
                button_table,
            },
        },
    }
end

function QueueView:onGrade(grade_name)
    local ok, err = pcall(function()
        local card = self.cards[self.current_idx]
        if not card then return end

        local result = SM20Engine:review(card, grade_name, self.interval_matrix, self.count_matrix)
        SM20Engine:recordIntoMatrix(card, result, self.interval_matrix, self.count_matrix)

        local next_review_date = os.date("!%Y-%m-%d %H:%M:%S",
            math.floor(os.time() + result.next_review_offset_days * 86400))

        table.insert(self.pending_reviews, {
            card_id          = result.card_id,
            grade            = result.grade,
            prev_stability   = result.prev_stability,
            new_stability    = result.new_stability,
            prev_interval    = result.prev_interval,
            new_interval     = result.new_interval,
            elapsed_days     = result.elapsed_days,
            new_difficulty   = result.new_difficulty,
            new_repetition   = result.new_repetition,
            next_review_date = next_review_date,
        })

        self.reviewed_count = self.reviewed_count + 1
        if self.grade_counts[grade_name] then
            self.grade_counts[grade_name] = self.grade_counts[grade_name] + 1
        end

        -- Batch flush every 10 reviews
        if #self.pending_reviews >= 10 then
            db:flushReviews(self.pending_reviews)
            self.pending_reviews = {}
        end

        self:_advance()
    end)

    if not ok then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = "Grade Error: " .. tostring(err),
            ok_text = _("Close"),
        })
    end
    return true
end

function QueueView:_advance()
    table.insert(self.prev_cards, self.current_idx)
    self.current_idx = self.current_idx + 1
    self.cloze_revealed = false

    if self.current_idx > self.total_cards then
        self:_flushAndClose()
        self:_showSummary()
        return
    end

    self:_buildUI()
    UIManager:setDirty(self, "full")
end

function QueueView:_goBack()
    if #self.prev_cards == 0 then return end
    self.current_idx = table.remove(self.prev_cards)
    self.cloze_revealed = false
    self:_buildUI()
    UIManager:setDirty(self, "full")
end

function QueueView:_flushAndClose()
    if #self.pending_reviews > 0 then
        db:flushReviews(self.pending_reviews)
        self.pending_reviews = {}
    end
    db:saveIntervalMatrix(self.interval_matrix, self.count_matrix)
end

-- End-of-session breakdown screen — replaces the old one-line toast.
function QueueView:_showSummary()
    local again = self.grade_counts.again
    local hard  = self.grade_counts.hard
    local good  = self.grade_counts.good
    local easy  = self.grade_counts.easy
    local total = again + hard + good + easy
    local retained = good + easy
    local accuracy = total > 0 and math.floor(retained / total * 100 + 0.5) or 0

    if has_keyvaluepage then
        UIManager:show(KeyValuePage:new{
            title = _("Session complete"),
            kv_pairs = {
                { _("Cards reviewed"), tostring(total) },
                { _("Accuracy"), string.format("%d%%  (%d of %d remembered)", accuracy, retained, total) },
                { "--", "--" },
                { _("Again"), tostring(again) },
                { _("Hard"),  tostring(hard) },
                { _("Good"),  tostring(good) },
                { _("Easy"),  tostring(easy) },
            },
            single_page = true,
        })
    else
        UIManager:show(InfoMessage:new{
            text = T(_("All done! Reviewed %1 cards. Accuracy: %2%%"),
                tostring(total), tostring(accuracy)),
        })
    end
end

function QueueView:onGoToSource()
    local card = self.cards[self.current_idx]
    if not card then return true end
    if not card.file_path or card.file_path == "" then
        UIManager:show(InfoMessage:new{
            text = _("Source document not available."),
        })
        return true
    end

    self:_flushAndClose()
    UIManager:close(self)

    local plugin = self.plugin
    if plugin and plugin.ui then
        local Event = require("ui/event")
        if card.file_path ~= plugin.ui.document.file then
            plugin.ui:switchDocument(card.file_path)
        end
        if card.xpointer then
            plugin.ui:handleEvent(Event:new("GotoXPointer", card.xpointer, card.xpointer))
        elseif card.page then
            plugin.ui:handleEvent(Event:new("GotoPage", card.page))
        end
    end
    return true
end

function QueueView:onClose()
    self:_flushAndClose()
    UIManager:close(self)
    return true
end

function QueueView:onSwipe(_, ges)
    if ges.direction == "north" then
        self:onGrade("good")
    elseif ges.direction == "south" then
        self:_goBack()
    elseif ges.direction == "west" then
        self:onGrade("good")
    elseif ges.direction == "east" then
        self:_goBack()
    end
    return true
end

function QueueView:onNextCard()
    self:onGrade("good")
    return true
end

function QueueView:onPrevCard()
    self:_goBack()
    return true
end

function QueueView:onShow()
    UIManager:setDirty(self, "full")
end

function QueueView:onCloseWidget()
    UIManager:setDirty(nil, "ui")
end

function QueueView:onEditCard()
    local card = self.cards[self.current_idx]
    if not card then return end
    if not has_inputdialog then
        UIManager:show(InfoMessage:new{ text = _("Editing not supported on this build.") })
        return
    end

    local dialog
    dialog = InputDialog:new{
        title = _("Edit Card Text"),
        input = card.text,
        input_hint = _("Use {{phrase}} for cloze deletion"),
        cursor_at_end = true,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local new_text = dialog:getInputText()
                        UIManager:close(dialog)
                        if new_text and new_text ~= "" and new_text ~= card.text then
                            db:updateCardText(card.id, new_text)
                            card.text = new_text
                            self:_buildUI()
                            UIManager:setDirty(self, "full")
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function QueueView:paintTo(bb, x, y)
    local ok, err = pcall(function()
        InputContainer.paintTo(self, bb, x, y)
    end)
    if not ok then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = "Paint Error: " .. tostring(err),
            ok_text = _("Close"),
        })
    end
end

return QueueView
