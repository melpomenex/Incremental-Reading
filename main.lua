local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local db = require("database")
local QueueView = require("queue_view")

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
        sorting_hint = "more_tools",
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
    local cards = db:getAllCards()
    local item_table = {}
    for _, card in ipairs(cards) do
        table.insert(item_table, {
            text = card.text:sub(1, 80) .. (card.text:len() > 80 and "…" or ""),
            mandatory = card.book_title,
            card = card,
        })
    end
    local menu = Menu:new{
        title = _("All cards"),
        item_table = item_table,
        is_borderless = true,
        is_popout = false,
        width = require("device").screen:getWidth(),
        height = require("device").screen:getHeight(),
        covers_fullscreen = true,
    }
    function menu:onMenuSelect(item)
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = item.card.text,
            ok_text = _("Delete"),
            ok_callback = function()
                db:deleteCard(item.card.id)
                menu:switchItemTable(menu.title, {})
                local updated = db:getAllCards()
                local new_items = {}
                for _, c in ipairs(updated) do
                    table.insert(new_items, {
                        text = c.text:sub(1, 80) .. (c.text:len() > 80 and "…" or ""),
                        mandatory = c.book_title,
                        card = c,
                    })
                end
                menu:switchItemTable(menu.title, new_items)
            end,
            cancel_text = _("Close"),
        })
    end
    UIManager:show(menu)
end

function IncReading:onShowStatistics()
    local KeyValuePage = require("ui/widget/keyvaluepage")
    local stats = db:getStatistics()
    UIManager:show(KeyValuePage:new{
        title = _("SRS Statistics"),
        kv_pairs = {
            { _("Total cards"), tostring(stats.total_cards) },
            { _("Cards due today"), tostring(stats.due_today) },
            { _("Total reviews"), tostring(stats.total_reviews) },
            { _("Average interval (days)"), string.format("%.1f", stats.avg_interval) },
        },
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
