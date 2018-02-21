defmodule EvercamMediaWeb.UserController do
  use EvercamMediaWeb, :controller
  alias EvercamMediaWeb.UserView
  alias EvercamMediaWeb.LogView
  alias EvercamMediaWeb.ErrorView
  alias EvercamMedia.Repo
  alias EvercamMedia.Util
  alias EvercamMedia.Intercom
  import EvercamMedia.Validation.Log
  require Logger

  def get(conn, params) do
    caller = conn.assigns[:current_user]
    user =
      params["id"]
      |> String.replace_trailing(".json", "")
      |> User.by_username_or_email

    cond do
      !user ->
        conn
        |> put_status(404)
        |> render(ErrorView, "error.json", %{message: "User does not exist."})
      !caller || !Permission.User.can_view?(caller, user) ->
        conn
        |> put_status(401)
        |> render(ErrorView, "error.json", %{message: "Unauthorized."})
      true ->
        conn
        |> render(UserView, "show.json", %{user: user})
    end
  end

  def credentials(conn, %{"id" => username} = params) do
    user =
      params["id"]
      |> String.replace_trailing(".json", "")
      |> User.by_username_or_email

    with :ok <- ensure_user_exists(user, username, conn),
         :ok <- password(params["password"], user, conn)
    do
      conn
      |> render(UserView, "credentials.json", %{user: user})
    end
  end

  def create(conn, params) do
    with :ok <- ensure_application(conn, params["token"]),
         :ok <- ensure_country(params["country"], conn)
    do
      requester_ip = user_request_ip(conn)
      user_agent = get_user_agent(conn)
      share_request_key = params["share_request_key"]
      api_id = UUID.uuid4(:hex) |> String.slice(0..7)
      api_key = UUID.uuid4(:hex)

      params =
        case Country.get_by_code(params["country"]) do
          {:ok, country} -> Map.merge(params, %{"country_id" => country.id}) |> Map.delete("country")
          {:error, nil} -> Map.delete(params, "country")
        end

      params = Map.merge(params, %{"api_id" => api_id, "api_key" => api_key})

      params =
        case has_share_request_key?(share_request_key) do
          true ->
            Map.merge(params, %{"confirmed_at" => Calendar.DateTime.to_erl(Calendar.DateTime.now_utc)})
            |> Map.delete("share_request_key")
          false ->
            Map.delete(params, "share_request_key")
        end

      changeset = User.changeset(%User{}, params)
      case Repo.insert(changeset) do
        {:ok, user} ->
          request_hex_code = UUID.uuid4(:hex)
          token = Ecto.build_assoc(user, :access_tokens, is_revoked: false,
            request: request_hex_code |> String.slice(0..31))

          case Repo.insert(token) do
            {:ok, token} -> {:success, user, token}
            {:error, changeset} -> {:invalid_token, changeset}
          end
          if !has_share_request_key?(share_request_key) do
            created_at =
              user.created_at
              |> Ecto.DateTime.to_erl
              |> Calendar.Strftime.strftime!("%Y-%m-%d %T UTC")

            code =
              :crypto.hash(:sha, user.username <> created_at)
              |> Base.encode16
              |> String.downcase

            share_default_camera(user)
            EvercamMedia.UserMailer.confirm(user, code)
            Intercom.intercom_activity(Application.get_env(:evercam_media, :create_intercom_user), user, user_agent, requester_ip)
          else
            share_request = CameraShareRequest.by_key_and_status(share_request_key)
            create_share_for_request(share_request, user, conn)
            Intercom.update_user(Application.get_env(:evercam_media, :create_intercom_user), user, user_agent, requester_ip)
          end
          share_requests = CameraShareRequest.by_email(user.email)
          multiple_share_create(share_requests, user, conn)
          Logger.info "[POST v1/users] [#{user_agent}] [#{requester_ip}] [#{user.username}] [#{user.email}] [#{params["token"]}]"
          conn
          |> put_status(:created)
          |> render(UserView, "show.json", %{user: user |> Repo.preload(:country, force: true)})
        {:error, changeset} ->
          render_error(conn, 400, Util.parse_changeset(changeset))
      end
    end
  end

  def user_exist(conn, %{"input" => input} = _params) do
    with %User{} <- User.by_username_or_email(input) do
      conn
      |> put_status(201)
      |> json(%{user: true})
    else
      nil ->
        conn
        |> put_status(404)
        |> json(%{user: false})
    end
  end

  def ensure_application(conn, token) when token in [nil, ""], do: render_error(conn, 400, "Invalid token.")
  def ensure_application(conn, token) do
    cond do
       System.get_env["WEB_APP"] == token -> :ok
       System.get_env["IOS_APP"] == token -> :ok
       System.get_env["ANDROID_APP"] == token -> :ok
       true -> render_error(conn, 400, "Invalid token.")
    end
  end

  def update(conn, %{"id" => username} = params) do
    current_user = conn.assigns[:current_user]
    user =
      params["id"]
      |> String.replace_trailing(".json", "")
      |> User.by_username

    with :ok <- ensure_user_exists(user, username, conn),
         :ok <- ensure_can_view(current_user, user, conn),
         :ok <- ensure_country(params["country"], conn)
    do
      user_params = %{
        firstname: firstname(params["firstname"], user),
        lastname: lastname(params["lastname"], user),
        email: email(params["email"], user)
      }
      user_params = case country(params["country"], user) do
        nil -> Map.delete(user_params, "country")
        country_id -> Map.merge(user_params, %{country_id: country_id}) |> Map.delete("country")
      end
      changeset = User.changeset(user, user_params)
      case Repo.update(changeset) do
        {:ok, user} ->
          updated_user = user |> Repo.preload(:country, force: true)
          conn |> render(UserView, "show.json", %{user: updated_user})
        {:error, changeset} ->
          render_error(conn, 400, Util.parse_changeset(changeset))
      end
    end
  end

  def delete(conn, %{"id" => username}) do
    current_user = conn.assigns[:current_user]
    user =
      username
      |> String.replace_trailing(".json", "")
      |> User.by_username

    with :ok <- ensure_user_exists(user, username, conn),
         :ok <- ensure_can_view(current_user, user, conn)
    do
      spawn(fn -> delete_user(user) end)
      json(conn, %{})
    end
  end

  def user_activities(conn, %{"id" => username} = params) do
    current_user = conn.assigns[:current_user]
    from = parse_from(params["from"])
    to = parse_to(params["to"])
    types = parse_types(params["types"])

    user =
      username
      |> String.replace_trailing(".json", "")
      |> User.by_username

    full_name = user |> User.get_fullname

    with :ok <- ensure_user_exists(user, username, conn),
         :ok <- ensure_can_view(current_user, user, conn),
         :ok <- params |> validate_params |> ensure_params(conn)
    do
      user_logs = CameraActivity.for_a_user(full_name, from, to, types)

      conn
      |> render(LogView, "user_logs.json", %{user_logs: user_logs})
    end
  end

  defp delete_user(user) do
    Camera.delete_by_owner(user.id)
    CameraShare.delete_by_user(user.id)
    CameraShareRequest.delete_by_user_id(user.id)
    User.delete_by_id(user.id)
    User.invalidate_auth(user.api_id, user.api_key)
    Camera.invalidate_user(user)
    User.invalidate_share_users(user)
    Intercom.delete_user(user.username)
  end

  defp firstname(firstname, user) when firstname in [nil, ""], do: user.firstname
  defp firstname(firstname, _user),  do: firstname

  defp lastname(lastname, user) when lastname in [nil, ""], do: user.lastname
  defp lastname(lastname, _user), do: lastname

  defp email(email, user) when email in [nil, ""], do: user.email
  defp email(email, _user), do: email

  defp country(country_id, user) when country_id in [nil, ""] do
    case user.country do
      nil -> nil
      country -> country.id
    end
  end
  defp country(country_id, _user) do
    country = Country.by_iso3166(country_id)
    country.id
  end

  defp ensure_user_exists(nil, username, conn) do
    render_error(conn, 404, "User '#{username}' does not exist.")
  end
  defp ensure_user_exists(_user, _id, _conn), do: :ok

  defp ensure_can_view(current_user, user, conn) do
    if current_user && Permission.User.can_view?(current_user, user) do
      :ok
    else
      render_error(conn, 403, "Unauthorized.")
    end
  end

  defp password(password, user, conn) do
    if Comeonin.Bcrypt.checkpw(password, user.password) do
      :ok
    else
      render_error(conn, 400, "Invalid password.")
    end
  end

  defp ensure_country(country_id, _conn) when country_id in [nil, ""], do: :ok
  defp ensure_country(country_id, conn) do
    country = Country.by_iso3166(country_id)
    case country do
      nil -> render_error(conn, 400, "Country isn't valid!")
      _ -> :ok
    end
  end

  defp has_share_request_key?(value) when value in [nil, ""], do: false
  defp has_share_request_key?(_value), do: true

  defp share_default_camera(user) do
    evercam_user = User.by_username("evercam")
    remembrance_camera = Camera.get_remembrance_camera
    rights = CameraShare.get_rights("public", evercam_user, remembrance_camera)
    message = "Default camera shared with newly created user."

    CameraShare.create_share(remembrance_camera, user, evercam_user, rights, message, "public")
  end

  defp create_share_for_request(nil, _user, conn), do: render_error(conn, 400, "Camera share request does not exist.")
  defp create_share_for_request(share_request, user, conn) do
    if share_request.email != user.email do
      render_error(conn, 400, "The email address specified does not match the share request email.")
    else
      share_request
      |> CameraShareRequest.changeset(%{status: 1})
      |> Repo.update
      |> case do
        {:ok, share_request} ->
          CameraShare.create_share(share_request.camera, user, share_request.user, share_request.rights, share_request.message)
          Camera.invalidate_camera(share_request.camera)
          accepted_request_notification(share_request)
        {:error, changeset} ->
          render_error(conn, 400, Util.parse_changeset(changeset))
      end
    end
  end

  defp multiple_share_create(nil, _user, _conn), do: Logger.info "No share request found."
  defp multiple_share_create(share_requests, user, conn) do
    Enum.each(share_requests, fn(share_request) -> create_share_for_request(share_request, user, conn) end)
  end

  defp parse_to(to) when to in [nil, ""], do: Calendar.DateTime.now_utc |> Calendar.DateTime.to_erl
  defp parse_to(to), do: to |> Calendar.DateTime.Parse.unix! |> Calendar.DateTime.to_erl

  defp parse_from(from) when from in [nil, ""], do: "2014-01-01T14:00:00Z" |> Ecto.DateTime.cast! |> Ecto.DateTime.to_erl
  defp parse_from(from), do: from |> Calendar.DateTime.Parse.unix! |> Calendar.DateTime.to_erl

  defp parse_types(types) when types in [nil, ""], do: nil
  defp parse_types(types), do: types |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp ensure_params(:ok, _conn), do: :ok
  defp ensure_params({:invalid, message}, conn), do: render_error(conn, 400, message)

  defp accepted_request_notification(share_request) do
    try do
      Task.start(fn ->
        EvercamMedia.UserMailer.accepted_share_request_notification(share_request.user, share_request.camera, share_request.email)
      end)
    catch _type, error ->
      Util.error_handler(error)
    end
  end
end
