#===============================================================================
# PEMK :: AuthUI  (client side)
#-------------------------------------------------------------------------------
# The in-game login / registration screen shown at the load crossroads when there
# is no valid session token AND no credentials in mmo_config.txt. Uses Essentials'
# own message/free-text widgets (pbMessageFreeText masks the password), so it
# works at the load screen exactly like its New Game / Continue menu.
#
# mmo_config.txt credentials remain a dev shortcut (they skip this screen), which
# keeps the two-window local test fast.
#===============================================================================
module PEMK
  module AuthUI
    module_function

    # Returns true if authenticated (Auth.apply_login ran), false if the player
    # chose to play offline.
    def run(c)
      PEMK.log("auth: showing in-game login/register screen")
      loop do
        choice = pbMessage(_INTL("Connect to the game server."),
                           [_INTL("Log in"), _INTL("Create account"), _INTL("Play offline")], 3)
        case choice
        when 0 then return true if login(c)
        when 1 then return true if register(c)
        else
          PEMK.log("auth: player chose offline")
          return false
        end
      end
    end

    def login(c)
      user = ask(_INTL("Enter your username:"), false, 20)
      return false if user.empty?

      pw = ask(_INTL("Enter your password:"), true, 64)
      return false if pw.empty?

      reply = PEMK::Auth.send_and_wait(c, { :type => :login, :username => user, :password => pw },
                                       [:login_ok, :login_err])
      return true if apply(reply, :login_ok)

      pbMessage(_INTL("Login failed: {1}.", friendly(reply)))
      false
    end

    def register(c)
      user = ask(_INTL("Choose a username (3-20 letters, digits or _):"), false, 20)
      return false if user.empty?

      email = ask(_INTL("Enter your email:"), false, 100)
      return false if email.empty?

      pw = ask(_INTL("Choose a password (at least 8 characters):"), true, 64)
      return false if pw.empty?

      if ask(_INTL("Confirm your password:"), true, 64) != pw
        pbMessage(_INTL("The passwords did not match."))
        return false
      end

      reg = PEMK::Auth.send_and_wait(c, { :type => :register, :username => user, :email => email, :password => pw },
                                     [:register_ok, :register_err])
      unless reg && reg[:type] == :register_ok
        pbMessage(_INTL("Could not create the account: {1}.", friendly(reg)))
        return false
      end

      reply = PEMK::Auth.send_and_wait(c, { :type => :login, :username => user, :password => pw },
                                       [:login_ok, :login_err])
      if apply(reply, :login_ok)
        pbMessage(_INTL("Welcome, {1}! Your account is ready.", user))
        return true
      end
      pbMessage(_INTL("Account created, but automatic login failed — pick \"Log in\"."))
      false
    end

    def apply(reply, ok_type)
      return false unless reply && reply[:type] == ok_type

      PEMK::Auth.apply_login(reply)
      true
    end

    # Free-text prompt (password-masked when +hidden+). Returns a stripped string.
    def ask(prompt, hidden, maxlen)
      (pbMessageFreeText(prompt, "", hidden, maxlen) || "").strip
    end

    def friendly(reply)
      case reply && reply[:reason]
      when "not_found"        then _INTL("no account with that username")
      when "bad_password"     then _INTL("wrong password")
      when "locked"           then _INTL("too many attempts, try again later")
      when "rate_limited"     then _INTL("too many attempts, wait a moment")
      when "taken"            then _INTL("that username is already taken")
      when "invalid_username" then _INTL("username must be 3-20 letters, digits or _")
      when "invalid_email"    then _INTL("that email looks invalid")
      when "weak_password"    then _INTL("password needs at least 8 characters")
      when nil                then _INTL("no response from the server")
      else (reply[:reason]).to_s
      end
    end
  end
end
