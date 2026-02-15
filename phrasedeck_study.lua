local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local CenterContainer = require("ui/widget/container/centercontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local Menu = require("ui/widget/menu")
local InputDialog = require("ui/widget/inputdialog")
local _ = require("gettext")
local logger = require("logger")
local PhraseDB = require("phrasedeck_db")

local VERTICAL_SPAN_SMALL = rawget(Size.span, "vertical_small") or rawget(Size.span, "vertical_default") or rawget(Size.span, "vertical_large") or 0

local StudyScreen = InputContainer:extend{}

function StudyScreen:init()
    local Screen = Device.screen
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    -- Book selection: nil = all books
    local books = PhraseDB.listBooks()
    local last_book_id = self.plugin and tonumber(self.plugin:readSetting("last_study_book_id"))
    self.book_id = nil
    self.book_title = _("All Books")

    if last_book_id then
        for _, b in ipairs(books) do
            if b.id == last_book_id then
                self.book_id = b.id
                self.book_title = b.title
                break
            end
        end
    end

    self.current_card = nil
    self.showing_back = false

    local card_width = math.floor(Screen:getWidth() * 0.85)
    local card_height = Size.item.height_large * 10

    local title_max_width = math.floor(Screen:getWidth() * 0.9)
    local title_face = Font:getFace("cfont", 26)
    local title_line_height_px = math.floor((1 + 0.3) * title_face.size)
    local title_height = title_line_height_px * 2
    self.title_widget = TextBoxWidget:new{
        face = title_face,
        text = self.book_title,
        width = title_max_width,
        height = title_height,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "center",
    }

    local card_inner_width = card_width - (Size.margin.default * 2 + Size.padding.fullscreen * 2 + Size.border.window * 2)
    local card_inner_height = card_height - (Size.margin.default * 2 + Size.padding.fullscreen * 2 + Size.border.window * 2)
    self.card_widget = TextBoxWidget:new{
        face = Font:getFace("cfont"),
        text = "",
        width = card_inner_width,
        height = card_inner_height,
        alignment = "center",
        height_overflow_show_ellipsis = true,
    }

    self.status_widget = TextWidget:new{
        face = Font:getFace("smallinfofont"),
        text = "",
    }

    -- Card container
    self.card_container = CenterContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = card_width, h = card_height },
        self.card_widget,
    }

    -- Card frame
    self.card_frame = FrameContainer:new{
        padding = Size.padding.fullscreen,
        margin = Size.margin.default,
        radius = Size.radius.window,
        bordersize = Size.border.window,
        self.card_container,
    }

    -- Top controls
    self.close_button = Button:new{
        text = _("Close"),
        callback = function()
            self:onClose()
        end,
        text_font_face = "cfont",
        text_font_size = 24,
        text_font_bold = false,
        bordersize = 0,
        margin = 0,
        radius = 0,
    }

    self.books_button = Button:new{
        text = _("Books"),
        callback = function()
            self:showBookSelection()
        end,
        text_font_face = "cfont",
        text_font_size = 24,
        text_font_bold = false,
        bordersize = 0,
        margin = 0,
        radius = 0,
    }

    self.settings_button = Button:new{
        text = _("Settings"),
        callback = function()
            self:showSettingsMenu()
        end,
        text_font_face = "cfont",
        text_font_size = 24,
        text_font_bold = false,
        bordersize = 0,
        margin = 0,
        radius = 0,
    }

    local separator = function()
        return TextWidget:new{
            face = Font:getFace("cfont", 22),
            text = "|",
        }
    end

    local top_controls = HorizontalGroup:new{
        align = "center",
        self.books_button,
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        separator(),
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        self.settings_button,
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        separator(),
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        self.close_button,
    }

    local top_bar = VerticalGroup:new{
        align = "center",
        top_controls,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        self.title_widget,
    }

    -- Show answer button row
    local show_row = ButtonTable:new{
        shrink_unneeded_width = true,
        width = math.floor(Screen:getWidth() * 0.85),
        buttons = {
            {
                {
                    id = "show_button",
                    text = _("Show answer"),
                    callback = function()
                        self:onShowOrNext()
                    end,
                },
            },
        },
    }
    self.show_button = show_row:getButtonById("show_button")

    -- Interval labels
    local small_interval_size = math.floor(Font.sizemap.smallinfofont * 0.85)
    local small_interval_face = Font:getFace("smallinfofont", small_interval_size)
    self.interval_again = TextWidget:new{ face = small_interval_face, text = "" }
    self.interval_hard = TextWidget:new{ face = small_interval_face, text = "" }
    self.interval_good = TextWidget:new{ face = small_interval_face, text = "" }
    self.interval_easy = TextWidget:new{ face = small_interval_face, text = "" }

    -- Rating buttons
    local btn_width = math.floor(Screen:getWidth() * 0.18)
    self.again_button = Button:new{
        text = _("Again"),
        callback = function() self:onRate("again") end,
        width = btn_width, bordersize = 0, margin = 0, radius = 0,
    }
    self.hard_button = Button:new{
        text = _("Hard"),
        callback = function() self:onRate("hard") end,
        width = btn_width, bordersize = 0, margin = 0, radius = 0,
    }
    self.good_button = Button:new{
        text = _("Good"),
        callback = function() self:onRate("good") end,
        width = btn_width, bordersize = 0, margin = 0, radius = 0,
    }
    self.easy_button = Button:new{
        text = _("Easy"),
        callback = function() self:onRate("easy") end,
        width = btn_width, bordersize = 0, margin = 0, radius = 0,
    }

    local col_again = VerticalGroup:new{
        align = "center",
        self.interval_again,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        self.again_button,
    }
    local col_hard = VerticalGroup:new{
        align = "center",
        self.interval_hard,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        self.hard_button,
    }
    local col_good = VerticalGroup:new{
        align = "center",
        self.interval_good,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        self.good_button,
    }
    local col_easy = VerticalGroup:new{
        align = "center",
        self.interval_easy,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        self.easy_button,
    }

    local rating_row = HorizontalGroup:new{
        align = "center",
        col_again,
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        col_hard,
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        col_good,
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        col_easy,
    }

    -- Front layout (phrase only + show answer)
    self.front_layout = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        top_bar,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        self.card_frame,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        show_row,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
    }

    -- Back layout (full card + ratings)
    self.back_layout = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        top_bar,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        self.card_frame,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        rating_row,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
    }

    self.active_layout = self.front_layout
    self[1] = self.front_layout

    self:setRatingButtonsEnabled(false)
    self:setShowButtonVisible(true)
    self:loadNextCard()

    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

function StudyScreen:setRatingButtonsEnabled(enabled)
    local flag = not not enabled
    if self.again_button then self.again_button:enableDisable(flag) end
    if self.hard_button then self.hard_button:enableDisable(flag) end
    if self.good_button then self.good_button:enableDisable(flag) end
    if self.easy_button then self.easy_button:enableDisable(flag) end
end

function StudyScreen:setShowButtonVisible(visible)
    if not self.show_button then
        return
    end
    if visible then
        self.show_button:enableDisable(true)
        self.show_button:setText(_("Show answer"))
    else
        self.show_button:enableDisable(false)
        self.show_button:setText("")
    end
end

function StudyScreen:updateRatingLabels(previews)
    if not previews then
        return
    end
    local function setLabel(widget, key)
        local info = previews[key]
        if info and widget then
            widget:setText(info.label or "")
        end
    end
    setLabel(self.interval_again, "again")
    setLabel(self.interval_hard, "hard")
    setLabel(self.interval_good, "good")
    setLabel(self.interval_easy, "easy")
end

function StudyScreen:loadNextCard()
    local randomize = false
    local daily_new_limit = 20
    if self.plugin then
        randomize = not not self.plugin:readSetting("randomize_cards", false)
        daily_new_limit = tonumber(self.plugin:readSetting("daily_new_cards_limit", 20)) or 20
    end

    local card = PhraseDB.fetchNextDueCard(self.book_id, nil, randomize, daily_new_limit)
    if not card then
        self.current_card = nil
        self.showing_back = false
        self.card_widget:setText(_("No cards due."))
        self:setShowButtonVisible(false)
        self:setRatingButtonsEnabled(false)
        self.active_layout = self.front_layout
        self[1] = self.front_layout
        self:refresh()
        return
    end
    self.current_card = card
    self.showing_back = false
    -- Front side: show only the phrase
    self.card_widget:setText(card.phrase)
    self:setShowButtonVisible(true)
    self:setRatingButtonsEnabled(false)
    self.active_layout = self.front_layout
    self[1] = self.front_layout
    self:refresh()
end

function StudyScreen:buildBackText(card)
    if not card then
        return ""
    end
    local parts = {}
    if card.phrase and card.phrase ~= "" then
        table.insert(parts, card.phrase)
    end
    if card.user_note and card.user_note ~= "" then
        table.insert(parts, "\n\n" .. card.user_note)
    end
    if card.sentence and card.sentence ~= "" then
        table.insert(parts, "\n\n" .. card.sentence)
    end
    return table.concat(parts)
end

function StudyScreen:onShowOrNext()
    if not self.current_card then
        self:loadNextCard()
        return
    end
    if not self.showing_back then
        self.showing_back = true
        self.card_widget:setText(self:buildBackText(self.current_card))
        local previews = PhraseDB.previewIntervals(self.current_card)
        self:updateRatingLabels(previews)
        self:setShowButtonVisible(false)
        self:setRatingButtonsEnabled(true)
        self.active_layout = self.back_layout
        self[1] = self.back_layout
        self:refresh()
    end
end

function StudyScreen:onRate(rating)
    if not self.current_card then
        return
    end
    local is_new_card = (self.current_card.reps == 0 and self.current_card.interval == 0)
    local updated = PhraseDB.updateCardScheduling(self.current_card, rating)
    if is_new_card and self.book_id then
        PhraseDB.incrementDailyNewCardsCount(self.book_id)
    end
    self.current_card = updated or self.current_card
    self.showing_back = false
    self:loadNextCard()
end

function StudyScreen:showBookSelection()
    local books = PhraseDB.listBooks()

    local study = self
    local items = {}

    -- "All Books" option
    table.insert(items, {
        text = string.format("%s (%d)", _("All Books"), PhraseDB.getCardCountForBook(nil)),
        keep_menu_open = false,
        callback = function()
            study.book_id = nil
            study.book_title = _("All Books")
            if study.title_widget and study.title_widget.setText then
                study.title_widget:setText(study.book_title)
            end
            if study.plugin then
                study.plugin:saveSetting("last_study_book_id", nil)
            end
            study:loadNextCard()
        end,
    })

    for _, b in ipairs(books) do
        local label = b.title or ""
        if label == "" then
            label = b.filepath or ("Book " .. tostring(b.id or ""))
        end
        if b.card_count and b.card_count > 0 then
            label = string.format("%s (%d)", label, b.card_count)
        end
        table.insert(items, {
            text = label,
            book_id = b.id,
            keep_menu_open = false,
            callback = function()
                study.book_id = b.id
                study.book_title = b.title or ""
                if study.title_widget and study.title_widget.setText then
                    study.title_widget:setText(study.book_title)
                end
                if study.plugin then
                    study.plugin:saveSetting("last_study_book_id", b.id)
                end
                study:loadNextCard()
            end,
        })
    end

    if #items <= 1 then
        UIManager:show(InfoMessage:new{
            text = _("No books with cards yet. Add phrases from the highlight menu while reading."),
            timeout = 4,
        })
        return
    end

    local screen = Device.screen
    local menu = Menu:new{
        title = _("Select Book"),
        item_table = items,
        covers_fullscreen = true,
        width = math.floor(screen:getWidth() * 0.9),
        height = math.floor(screen:getHeight() * 0.9),
    }

    function menu:onMenuChoice(item)
        if item.callback then
            item.callback()
        end
        UIManager:close(self)
        return true
    end

    function menu:onMenuHold(item)
        if not item or not item.book_id then
            return true
        end
        local book_label = item.text or _("this book")
        UIManager:show(ConfirmBox:new{
            text = string.format(_("Delete %s and all its cards?"), book_label),
            ok_text = _("Delete"),
            ok_callback = function()
                PhraseDB.deleteBook(item.book_id)
                -- If the deleted book was the active study book, reset to all books
                if study.book_id == item.book_id then
                    study.book_id = nil
                    study.book_title = _("All Books")
                    if study.title_widget and study.title_widget.setText then
                        study.title_widget:setText(study.book_title)
                    end
                    if study.plugin then
                        study.plugin:saveSetting("last_study_book_id", nil)
                    end
                end
                UIManager:close(menu)
                study:loadNextCard()
            end,
        })
        return true
    end

    UIManager:show(menu)
end

function StudyScreen:showSettingsMenu()
    local study = self
    local screen = Device.screen
    local menu

    local items = {
        {
            text = _("Randomize cards with same due"),
            keep_menu_open = true,
            mandatory_func = function()
                if not study.plugin then return "OFF" end
                if study.plugin:readSetting("randomize_cards", false) then
                    return "ON"
                end
                return "OFF"
            end,
            checked_func = function()
                if not study.plugin then return false end
                return not not study.plugin:readSetting("randomize_cards", false)
            end,
            callback = function()
                if not study.plugin then return end
                local current = not not study.plugin:readSetting("randomize_cards", false)
                study.plugin:saveSetting("randomize_cards", not current)
                if menu and menu.updateItems then
                    menu:updateItems(1, true)
                end
            end,
        },
        {
            text = _("Daily new cards limit"),
            keep_menu_open = true,
            mandatory_func = function()
                if not study.plugin then return "20" end
                local limit = tonumber(study.plugin:readSetting("daily_new_cards_limit", 20))
                if limit == 0 then return _("Unlimited") end
                return tostring(limit)
            end,
            callback = function()
                if not study.plugin then return end
                local current_limit = tonumber(study.plugin:readSetting("daily_new_cards_limit", 20))
                local input_dialog
                input_dialog = InputDialog:new{
                    title = _("Daily new cards limit"),
                    input = tostring(current_limit),
                    input_type = "number",
                    description = _("Maximum number of new cards per day. 0 = unlimited."),
                    buttons = {
                        {
                            {
                                text = _("Cancel"),
                                callback = function()
                                    UIManager:close(input_dialog)
                                end,
                            },
                            {
                                text = _("Save"),
                                is_enter_default = true,
                                callback = function()
                                    local new_limit = tonumber(input_dialog:getInputText()) or 20
                                    if new_limit < 0 then new_limit = 0 end
                                    study.plugin:saveSetting("daily_new_cards_limit", new_limit)
                                    UIManager:close(input_dialog)
                                    if menu and menu.updateItems then
                                        menu:updateItems(2, true)
                                    end
                                end,
                            },
                        },
                    },
                }
                UIManager:show(input_dialog)
                input_dialog:onShowKeyboard()
            end,
        },
        {
            text = _("Context words count"),
            keep_menu_open = true,
            mandatory_func = function()
                if not study.plugin then return "50" end
                return tostring(tonumber(study.plugin:readSetting("context_words", 50)) or 50)
            end,
            callback = function()
                if not study.plugin then return end
                local current = tonumber(study.plugin:readSetting("context_words", 50)) or 50
                local input_dialog
                input_dialog = InputDialog:new{
                    title = _("Context words count"),
                    input = tostring(current),
                    input_type = "number",
                    description = _("Number of words to capture around selected phrase for sentence extraction."),
                    buttons = {
                        {
                            {
                                text = _("Cancel"),
                                callback = function()
                                    UIManager:close(input_dialog)
                                end,
                            },
                            {
                                text = _("Save"),
                                is_enter_default = true,
                                callback = function()
                                    local val = tonumber(input_dialog:getInputText()) or 50
                                    if val < 10 then val = 10 end
                                    study.plugin:saveSetting("context_words", val)
                                    UIManager:close(input_dialog)
                                    if menu and menu.updateItems then
                                        menu:updateItems(3, true)
                                    end
                                end,
                            },
                        },
                    },
                }
                UIManager:show(input_dialog)
                input_dialog:onShowKeyboard()
            end,
        },
        {
            text = _("Close"),
            keep_menu_open = false,
            callback = function()
                if menu then
                    UIManager:close(menu)
                end
            end,
        },
    }

    menu = Menu:new{
        title = _("Settings"),
        item_table = items,
        covers_fullscreen = true,
        width = math.floor(screen:getWidth() * 0.9),
        height = math.floor(screen:getHeight() * 0.9),
    }

    function menu:onMenuChoice(item)
        if item.callback then
            item.callback()
        end
        if not item.keep_menu_open then
            UIManager:close(self)
        end
        return true
    end

    UIManager:show(menu)
end

function StudyScreen:onClose()
    UIManager:close(self)
    UIManager:setDirty(nil, "full")
    return true
end

function StudyScreen:onCloseWidget()
    UIManager:setDirty(nil, "full")
end

function StudyScreen:refresh()
    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

function StudyScreen:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    if self[1] then
        local content_size = self[1]:getSize()
        local offset_x = x + math.floor((self.dimen.w - content_size.w) / 2)
        local offset_y = y + math.floor((self.dimen.h - content_size.h) / 2)
        self[1]:paintTo(bb, offset_x, offset_y)
    end
end

return StudyScreen
