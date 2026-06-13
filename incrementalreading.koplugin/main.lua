local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local db = require("database")
local QueueView = require("queue_view")
local SM20Engine = require("srs_engine")

local IncReading = WidgetContainer:extend{
    name = "incremental_reading",
    is_doc_only = false,
}

function IncReading:init()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
end

function IncReading:onReaderReady()
    if self.ui.highlight then
        self:registerHighlightButton()
    end
end

function IncReading:addToMainMenu(menu_items)
    menu_items.incremental_reading = {
        text_func = function()
            local count = db:getDueCount()
            return T(_("Review Queue (%1)"), count)
        end,
        sorting_hint = self.ui.document and "typeset" or "more_tools",
        callback = function()
            self:onOpenReviewQueue()
        end,
        sub_item_table = {
            {
                text = _("Start review"),
                callback = function()
                    self:onOpenReviewQueue()
                end,
            },
            {
                text = _("Browse cards"),
                callback = function()
                    self:onBrowseCards()
                end,
            },
            {
                text = _("Statistics"),
                callback = function()
                    self:onShowStatistics()
                end,
            },
            {
                text = _("Reset database"),
                keep_menu_open = true,
                callback = function()
                    self:onResetDatabase()
                end,
            },
        },
    }
end

function IncReading:registerHighlightButton()
    self.ui.highlight:addToHighlightDialog("12_export_srs", function(this)
        return {
            text = _("Export to SRS"),
            callback = function()
                self:onExportHighlight(this)
            end,
        }
    end)
end

function IncReading:onExportHighlight(highlight)
    local ok, err = pcall(function()
        highlight:highlightFromHoldPos()
        local selected_text = highlight.selected_text
        if not selected_text or not selected_text.text then
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{text = _("Error: No selected text found!")})
            return
        end
        
        local util = require("util")
        local text = util.cleanupSelectedText(selected_text.text)
        local file_path = self.ui.document.file
        
        local ffiUtil = require("ffi/util")
        local props = self.ui.document:getProps()
        local book_title = props and props.title or ""
        if book_title == "" then
            book_title = ffiUtil.basename(file_path)
        end
        
        local xpointer = nil
        local page = nil
        local chapter = ""
        if selected_text.pos0 then
            xpointer = selected_text.pos0
        end
        if self.ui.document.info and self.ui.document.info.has_pages then
            page = self.ui.document:getCurrentPage()
        end
        if self.ui.toc then
            chapter = self.ui.toc:getTocTitleByPage(selected_text.pos0 or self.ui.document:getCurrentPage())
        end

        if db:isDuplicate(text, file_path, xpointer) then
            Notification:notify(_("Already in queue"))
            highlight:onClose()
            return
        end
        db:insertCard(text, book_title, file_path, xpointer, page, chapter)
        Notification:notify(_("Added to review queue"))
        highlight:onClose()
    end)
    
    if not ok then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = "Export Error: " .. tostring(err),
            ok_text = _("Close"),
        })
    end
end

function IncReading:onOpenReviewQueue()
    local ok, err = pcall(function()
        local cards = db:getDueCards()
        if #cards == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No cards due for review. Come back later!"),
            })
            return
        end
        local view = QueueView:new{
            cards = cards,
            plugin = self,
        }
        UIManager:show(view)
    end)
    
    if not ok then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = "Review Error: " .. tostring(err),
            ok_text = _("Close"),
        })
    end
end

function IncReading:onBrowseCards()
    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen

    local function build_items()
        local cards = db:getAllCards()
        local items = {}
        for _, card in ipairs(cards) do
            local preview = card.text:gsub("%s+", " "):sub(1, 80)
            if card.text:len() > 80 then preview = preview .. "…" end
            local badge
            if card.suspended then
                badge = _("suspended")
            else
                badge = SM20Engine.formatInterval(card.stability)
            end
            table.insert(items, {
                text = preview,
                mandatory = badge,
                card = card,
            })
        end
        return items
    end

    local menu = Menu:new{
        title = _("All cards"),
        item_table = build_items(),
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        covers_fullscreen = true,
    }

    local function refresh()
        menu:switchItemTable(menu.title, build_items())
    end

    function menu:onMenuSelect(item)
        local card = item.card
        local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
        local dialog
        dialog = ButtonDialogTitle:new{
            title = card.text,
            title_align = "center",
            buttons = {
                {
                    {
                        text = _("Open in book"),
                        callback = function()
                            UIManager:close(dialog)
                            UIManager:close(menu)
                            IncReading:_jumpToCard(card)
                        end,
                    },
                    {
                        text = _("Edit"),
                        callback = function()
                            UIManager:close(dialog)
                            IncReading:_editCardText(card, function()
                                refresh()
                            end)
                        end,
                    },
                },
                {
                    {
                        text = card.suspended and _("Unsuspend") or _("Suspend"),
                        callback = function()
                            db:setCardSuspended(card.id, not card.suspended)
                            UIManager:close(dialog)
                            refresh()
                        end,
                    },
                    {
                        text = _("Delete"),
                        callback = function()
                            db:deleteCard(card.id)
                            UIManager:close(dialog)
                            local Notification = require("ui/widget/notification")
                            Notification:notify(_("Card deleted"))
                            refresh()
                        end,
                    },
                },
                {
                    {
                        text = _("Close"),
                        callback = function()
                            UIManager:close(dialog)
                        end,
                    },
                },
            },
        }
        UIManager:show(dialog)
    end

    UIManager:show(menu)
end

function IncReading:_editCardText(card, on_saved)
    local InputDialog = require("ui/widget/inputdialog")
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
                            if on_saved then on_saved() end
                            local Notification = require("ui/widget/notification")
                            Notification:notify(_("Card updated"))
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function IncReading:_jumpToCard(card)
    if not card.file_path or card.file_path == "" then
        UIManager:show(InfoMessage:new{ text = _("Source document not available.") })
        return
    end
    local ui = self.ui
    if not ui then return end
    local Event = require("ui/event")
    if card.file_path ~= ui.document.file then
        ui:switchDocument(card.file_path)
    end
    if card.xpointer then
        ui:handleEvent(Event:new("GotoXPointer", card.xpointer, card.xpointer))
    elseif card.page then
        ui:handleEvent(Event:new("GotoPage", card.page))
    end
end

function IncReading:onShowStatistics()
    local KeyValuePage = require("ui/widget/keyvaluepage")
    local stats = db:getStatistics()
    local retention_pct = math.floor((stats.retention or 0) * 100 + 0.5)
    UIManager:show(KeyValuePage:new{
        title = _("SRS Statistics"),
        kv_pairs = {
            { _("Total cards"), tostring(stats.total_cards) },
            { _("Mature cards (≥ 21d)"), tostring(stats.mature_cards or 0) },
            { _("Current streak (days)"), tostring(stats.streak or 0) },
            { "--", "--" },
            { _("Due now"), tostring(stats.due_today) },
            { _("Due in 24h"), tostring(stats.due_24h or 0) },
            { _("Due this week"), tostring(stats.due_week or 0) },
            { "--", "--" },
            { _("Total reviews"), tostring(stats.total_reviews) },
            { _("Retention"), string.format("%d%%  (%d remembered)", retention_pct, math.floor((stats.retention or 0) * (stats.total_reviews or 0) + 0.5)) },
            { _("Avg. interval"), SM20Engine.formatInterval(stats.avg_interval) },
        },
        single_page = true,
    })
end

function IncReading:onResetDatabase()
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Reset the SRS database? This will delete all cards, review history, and scheduling data."),
        ok_text = _("Reset"),
        ok_callback = function()
            db:resetDatabase()
            Notification:notify(_("Database reset"))
        end,
    })
end

function IncReading:onDispatcherRegisterActions()
    Dispatcher:registerAction("open_review_queue", {
        category = "none",
        event = "OpenReviewQueue",
        title = _("Open review queue"),
        general = true,
    })
end

return IncReading
