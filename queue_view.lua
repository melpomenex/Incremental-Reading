local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local OverlapGroup = require("ui/widget/overlapgroup")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local TitleBar = require("ui/widget/titlebar")
local TextBoxWidget = require("ui/widget/textboxwidget")
local ButtonTable = require("ui/widget/buttontable")
local Button = require("ui/widget/button")
local TextWidget = require("ui/widget/textwidget")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Geom = require("ui/geometry")
local Screen = require("device").screen
local Device = require("device")
local Font = require("ui/font")
local Size = require("ui/size")
local GestureRange = require("ui/gesturerange")
local _ = require("gettext")
local T = require("ffi/util").template

local db = require("database")
local SM20Engine = require("srs_engine")

local QueueView = InputContainer:extend{
    covers_fullscreen = true,
}

function QueueView:init()
    self.dimen = Geom:new{
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }

    self.current_idx = 1
    self.cards = self.cards or {}
    self.total_cards = #self.cards
    self.reviewed_count = 0
    self.pending_reviews = {}
    self.prev_cards = {}

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

function QueueView:_buildUI()
    local card = self.cards[self.current_idx]
    if not card then
        self[1] = FrameContainer:new{
            height = self.dimen.h,
            padding = 0,
            bordersize = 0,
            background = require("ffi/blitbuffer").COLOR_WHITE,
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

    local progress_text = T(_("Reviewed: %1/%2"), self.reviewed_count, self.total_cards)

    self.title_bar = TitleBar:new{
        width = self.dimen.w,
        title = card.book_title,
        subtitle = card.chapter ~= "" and card.chapter or nil,
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

    local content_height = self.dimen.h
        - self.title_bar:getHeight()
        - Size.padding.default * 4
        - Size.item.height_default * 2

    self.text_widget = TextBoxWidget:new{
        text = card.text,
        face = Font:getFace("x_textinfo"),
        width = self.dimen.w - Size.padding.fullscreen * 2,
        height = content_height,
        scroll = true,
        scroll_bar_width = Size.padding.small,
        dialog = self,
    }

    self.progress_widget = TextWidget:new{
        text = progress_text,
        face = Font:getFace("infofont"),
    }

    local grade_buttons = {
        {
            {
                text = _("Again"),
                callback = function()
                    self:onGrade("again")
                end,
            },
            {
                text = _("Hard"),
                callback = function()
                    self:onGrade("hard")
                end,
            },
            {
                text = _("Good"),
                callback = function()
                    self:onGrade("good")
                end,
            },
            {
                text = _("Easy"),
                callback = function()
                    self:onGrade("easy")
                end,
            },
        },
    }

    local button_table = ButtonTable:new{
        width = self.dimen.w,
        buttons = grade_buttons,
        show_parent = self,
    }

    local content = VerticalGroup:new{
        align = "left",
        self.title_bar,
        self.progress_widget,
        self.text_widget,
    }

    self[1] = FrameContainer:new{
        height = self.dimen.h,
        padding = 0,
        bordersize = 0,
        background = require("ffi/blitbuffer").COLOR_WHITE,
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
    local card = self.cards[self.current_idx]
    if not card then return true end

    local result = SM20Engine:review(card, grade_name, self.interval_matrix, self.count_matrix)
    SM20Engine:recordIntoMatrix(card, result, self.interval_matrix, self.count_matrix)

    local next_review_date = os.date("!%Y-%m-%d %H:%M:%S",
        os.time() + result.next_review_offset_days * 86400)

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

    -- Batch flush every 10 reviews
    if #self.pending_reviews >= 10 then
        db:flushReviews(self.pending_reviews)
        self.pending_reviews = {}
    end

    self:_advance()
    return true
end

function QueueView:_advance()
    table.insert(self.prev_cards, self.current_idx)
    self.current_idx = self.current_idx + 1

    if self.current_idx > self.total_cards then
        self:_flushAndClose()
        UIManager:show(InfoMessage:new{
            text = T(_("All done! Reviewed %1 cards."), self.reviewed_count),
        })
        return
    end

    self:_buildUI()
    UIManager:setDirty(self, "full")
end

function QueueView:_goBack()
    if #self.prev_cards == 0 then return end
    self.current_idx = table.remove(self.prev_cards)
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

return QueueView
