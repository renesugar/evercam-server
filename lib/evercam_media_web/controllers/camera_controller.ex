defmodule EvercamMediaWeb.CameraController do
  use EvercamMediaWeb, :controller
  alias EvercamMediaWeb.CameraView
  alias EvercamMediaWeb.ErrorView
  alias EvercamMedia.Repo
  alias EvercamMedia.Snapshot.Storage
  alias EvercamMedia.Snapshot.WorkerSupervisor
  alias EvercamMedia.TimelapseRecording.TimelapseRecordingSupervisor
  alias EvercamMedia.Snapshot.CamClient
  alias EvercamMedia.Zoho
  alias EvercamMedia.Util
  require Logger
  import String, only: [to_integer: 1]

  def port_check(conn, params) do
    case check_params(params) do
      {:invalid, message} ->
        json(conn, %{error: message})
      :ok ->
        response = %{
          address: params["address"],
          port: to_integer(params["port"]),
          open: Util.port_open?(params["address"], params["port"])
        }
        json(conn, response)
    end
  end

  def index(conn, params) do
    requester = conn.assigns[:current_user]

    if requester do
      requested_user =
        case requester do
          %User{} -> requester
          %AccessToken{} -> User.by_username(params["user_id"])
        end

      include_shared? =
        case params["include_shared"] do
          "false" -> false
          "true" -> true
          _ -> true
        end

      data = ConCache.get_or_store(:cameras, "#{requested_user.username}_#{include_shared?}", fn() ->
        cameras =
          Camera.for(requested_user, include_shared?)
          |> Enum.sort_by(fn(camera) -> String.downcase(camera.name) end)
        Phoenix.View.render(CameraView, "index.json", %{cameras: cameras, user: requester})
      end)

      json(conn, data)
    else
      conn
      |> put_status(404)
      |> render(ErrorView, "error.json", %{message: "Not found."})
    end
  end

  def show(conn, params) do
    current_user = conn.assigns[:current_user]
    camera =
      params["id"]
      |> String.replace_trailing(".json", "")
      |> Camera.get_full

    if Permission.Camera.can_list?(current_user, camera) do
      conn
      |> render("show.json", %{camera: camera, user: current_user})
    else
      conn
      |> put_status(404)
      |> render(ErrorView, "error.json", %{message: "Not found."})
    end
  end

  def transfer(conn, %{"id" => exid, "user_id" => user_id}) do
    current_user = conn.assigns[:current_user]
    camera = Camera.get_full(exid)
    user = User.by_username_or_email(user_id)

    with :ok <- is_authorized(conn, current_user),
         :ok <- camera_exists(conn, exid, camera),
         :ok <- user_exists(conn, user_id, user),
         :ok <- has_rights(conn, current_user, camera)
    do
      old_owner = camera.owner
      CameraShare.delete_share(user, camera)
      camera = change_camera_owner(user, camera)
      rights = CameraShare.rights_list("full") |> Enum.join(",")
      CameraShare.create_share(camera, old_owner, user, rights, "")
      update_camera_worker(Application.get_env(:evercam_media, :run_spawn), camera.exid)

      conn
      |> render("show.json", %{camera: camera, user: current_user})
    end
  end

  def update(conn, %{"id" => exid} = params) do
    caller = conn.assigns[:current_user]
    old_camera = Camera.get_full(exid)

    with :ok <- camera_exists(conn, exid, old_camera),
         :ok <- user_has_rights(conn, caller, old_camera)
    do
      camera_changeset = camera_update_changeset(old_camera, params, caller.email)
      with true <- camera_changeset.changes == %{} do
        conn
        |> render("show.json", %{camera: old_camera, user: caller})
      else
        false ->
          case Repo.update(camera_changeset) do
            {:ok, camera} ->
              Camera.invalidate_camera(camera)
              camera = Camera.get_full(camera.exid)
              CameraActivity.log_activity(caller, camera, "edited",
                %{
                  ip: user_request_ip(conn),
                  agent: get_user_agent(conn),
                  cam_settings: add_settings_key(old_camera, camera, camera_changeset.changes)
                }
              )
              update_camera_worker(Application.get_env(:evercam_media, :run_spawn), camera.exid)
              conn
              |> render("show.json", %{camera: camera, user: caller})
            {:error, changeset} ->
              render_error(conn, 400, Util.parse_changeset(changeset))
          end
      end
    end
  end

  defp add_settings_key(old_camera, camera, changes) do
    case Map.has_key?(changes, :config) do
      true ->
        %{
          old: set_settings(old_camera),
          new: set_settings(camera)
        }
      false ->
        false
    end
  end

  defp set_settings(camera) do
    %{
      external_host: Util.deep_get(camera, [:config, "external_host"], ""),
      external_http_port: Util.deep_get(camera, [:config, "external_http_port"], ""),
      external_rtsp_port: Util.deep_get(camera, [:config, "external_rtsp_port"], ""),
      snapshot_url: Util.deep_get(camera, [:config, "snapshots", "jpg"], ""),
      auth: Util.deep_get(camera, [:config, "auth", "basic"], ""),
      vendor_model_name: camera.vendor_model.name,
      vendor_name: camera.vendor_model.vendor.name
    }
  end

  def delete(conn, %{"id" => exid}) do
    caller = conn.assigns[:current_user]
    camera = Camera.get_full(exid)

    with :ok <- camera_exists(conn, exid, camera),
         true <- user_has_delete_rights(conn, caller, camera)
    do
      admin_user = User.by_username("evercam")
      camera_params = %{
        owner_id: admin_user.id,
        discoverable: false,
        is_public: false
      }
      camera
      |> Camera.delete_changeset(camera_params)
      |> Repo.update!

      spawn(fn -> delete_snapshot_worker(camera) end)
      spawn(fn -> delete_camera_worker(camera) end)
      json(conn, %{})
    end
  end

  def create(conn, params) do
    caller = conn.assigns[:current_user]

    with :ok <- is_authorized(conn, caller)
    do
      params
      |> Map.merge(%{"owner_id" => caller.id})
      |> camera_create_changeset(caller.email)
      |> Repo.insert
      |> case do
        {:ok, camera} ->
          full_camera =
            camera
            |> Repo.preload(:owner, force: true)
            |> Repo.preload(:timelapse_recordings, force: true)
            |> Repo.preload(:cloud_recordings, force: true)
            |> Repo.preload(:vendor_model, force: true)
            |> Repo.preload([vendor_model: :vendor], force: true)
          CameraActivity.log_activity(caller, camera, "created", %{ip: user_request_ip(conn), agent: get_user_agent(conn)})
          Camera.invalidate_user(caller)
          send_email_notification(Application.get_env(:evercam_media, :run_spawn), caller, full_camera)
          add_camera_to_zoho(Application.get_env(:evercam_media, :run_spawn), full_camera, caller.username)
          conn
          |> put_status(:created)
          |> render("show.json", %{camera: full_camera, user: caller})
        {:error, changeset} ->
          Logger.info "[camera-create] [#{inspect params}] [#{inspect Util.parse_changeset(changeset)}]"
          render_error(conn, 400, Util.parse_changeset(changeset))
      end
    end
  end

  defp add_camera_to_zoho(true, camera, user_id) when user_id in ["garda", "gardashared", "construction", "oldconstruction", "smartcities"] do
    spawn fn ->
      case Zoho.get_camera(camera.exid) do
        {:ok, _} -> Logger.info "[add_camera_to_zoho] [#{camera.exid}] [Camera already exists]"
        _ -> Zoho.insert_camera([camera])
      end
    end
  end
  defp add_camera_to_zoho(_mode, _camera, user_id), do: :noop

  defp check_params(params) do
    with :ok <- validate("address", params["address"]),
         :ok <- validate("port", params["port"]),
         do: :ok
  end

  defp validate(key, value) when value in [nil, ""], do: invalid(key)

  defp validate("address", value) do
    if Camera.valid?("address", value), do: :ok, else: invalid("address")
  end

  defp validate("port", value) when is_integer(value) and value >= 1 and value <= 65_535, do: :ok
  defp validate("port", value) when is_binary(value) do
    case Integer.parse(value) do
      {int_value, ""} -> validate("port", int_value)
      _ -> invalid("port")
    end
  end
  defp validate("port", _), do: invalid("port")

  defp invalid(key), do: {:invalid, "The parameter '#{key}' isn't valid."}

  defp is_authorized(conn, nil) do
    conn
    |> put_status(401)
    |> render(ErrorView, "error.json", %{message: "Unauthorized."})
  end
  defp is_authorized(_conn, _user), do: :ok

  defp camera_exists(conn, camera_exid, nil) do
    conn
    |> put_status(404)
    |> render(ErrorView, "error.json", %{message: "The #{camera_exid} camera does not exist."})
  end
  defp camera_exists(_conn, _camera_exid, _camera), do: :ok

  defp user_exists(conn, user_id, nil) do
    conn
    |> put_status(404)
    |> render(ErrorView, "error.json", %{message: "User '#{user_id}' does not exist."})
  end
  defp user_exists(_conn, _user_id, _user), do: :ok

  defp has_rights(conn, user, camera) do
    if Camera.is_owner?(user, camera) do
      :ok
    else
      conn
      |> put_status(403)
      |> render(ErrorView, "error.json", %{message: "Unauthorized."})
    end
  end

  defp update_camera_worker(true, exid) do
    spawn fn ->
      exid |> Camera.get_full |> Camera.invalidate_camera
      camera = exid |> Camera.get_full

      exid
      |> String.to_atom
      |> Process.whereis
      |> WorkerSupervisor.update_worker(camera)

      "timelapse_#{exid}"
      |> String.to_atom
      |> Process.whereis
      |> TimelapseRecordingSupervisor.update_worker(camera)
    end
  end
  defp update_camera_worker(_mode, _exid), do: :noop

  defp change_camera_owner(user, camera) do
    camera
    |> Camera.changeset(%{owner_id: user.id})
    |> Repo.update!
    |> Repo.preload(:owner, force: true)
  end

  defp user_has_rights(conn, user, camera) do
    if !Permission.Camera.can_edit?(user, camera) do
      conn
      |> put_status(403)
      |> render(ErrorView, "error.json", %{message: "Unauthorized."})
    else
      :ok
    end
  end

  defp user_has_delete_rights(conn, user, camera) do
    if !Permission.Camera.can_delete?(user, camera) do
      conn
      |> put_status(403)
      |> render(ErrorView, "error.json", %{message: "Unauthorized."})
    else
      true
    end
  end

  defp camera_update_changeset(camera, params, caller_email) do
    camera_params =
      %{config: Map.get(camera, :config)}
      |> construct_camera_parameters("update", params)
      |> add_alert_email(camera.alert_emails, caller_email, params["is_online_email_owner_notification"])

    Camera.changeset(camera, camera_params)
  end

  defp camera_create_changeset(params, caller_email) do
    camera_params =
      %{config: %{"snapshots" => %{}}}
      |> add_parameter("field", :owner_id, params["owner_id"])
      |> construct_camera_parameters("create", params)
      |> add_alert_email([], caller_email, params["is_online_email_owner_notification"])

    Camera.changeset(%Camera{}, camera_params)
  end

  defp construct_camera_parameters(camera, action, params) do
    model = VendorModel.get_model(action, params["vendor"], params["model"])

    camera
    |> add_parameter("field", :name, params["name"])
    |> add_parameter("field", :exid, params["id"])
    |> add_parameter("field", :timezone, params["timezone"])
    |> add_parameter("field", :mac_address, params["mac_address"])
    |> add_parameter("field", :is_online, params["is_online"])
    |> add_parameter("field", :discoverable, params["discoverable"])
    |> add_parameter("field", :location_lng, params["location_lng"])
    |> add_parameter("field", :location_lat, params["location_lat"])
    |> add_parameter("field", :is_public, params["is_public"])
    |> add_parameter("model", :model_id, model)
    |> add_parameter("host", "external_host", params["external_host"])
    |> add_parameter("host", "secondary_port", params["secondary_port"])
    |> add_parameter("host", "external_http_port", params["external_http_port"])
    |> add_parameter("host", "external_rtsp_port", params["external_rtsp_port"])
    |> add_parameter("host", "nvr_http_port", params["nvr_http_port"])
    |> add_parameter("host", "nvr_rtsp_port", params["nvr_rtsp_port"])
    |> add_parameter("host", "internal_host", params["internal_host"])
    |> add_parameter("host", "internal_http_port", params["internal_http_port"])
    |> add_parameter("host", "internal_rtsp_port", params["internal_rtsp_port"])
    |> add_url_parameter(model, "jpg", "jpg", params["jpg_url"])
    |> add_url_parameter(model, "mjpg", "mjpg", params["mjpg_url"])
    |> add_url_parameter(model, "h264", "h264", params["h264_url"])
    |> add_url_parameter(model, "audio", "audio", params["audio_url"])
    |> add_url_parameter(model, "mpeg", "mpeg4", params["mpeg_url"])
    |> add_parameter("auth", "username", params["cam_username"])
    |> add_parameter("auth", "password", params["cam_password"])
  end

  defp add_alert_email(params, emails, caller_email, send_notification) when send_notification in [true, "true"] do
    alert_emails =
      emails
      |> Util.get_list
      |> Enum.reject(fn(email) -> email == caller_email end)
      |> List.insert_at(-1, caller_email)
      |> Enum.join(",")

    add_parameter(params, "field", :alert_emails, alert_emails)
  end
  defp add_alert_email(params, emails, caller_email, send_notification) when send_notification in [false, "false"] do
    alert_emails =
      emails
      |> Util.get_list
      |> Enum.reject(fn(email) -> email == caller_email end)
      |> Enum.join(",")

    add_parameter(params, "field", :alert_emails, alert_emails)
  end
  defp add_alert_email(params, _emails, _caller_email, _send_notification), do: params

  defp add_parameter(params, _field, _key, nil), do: params
  defp add_parameter(params, "field", key, value) do
    Map.put(params, key, value)
  end
  defp add_parameter(params, "model", key, value) do
    Map.put(params, key, value.id)
  end
  defp add_parameter(params, "host", key, value) do
    put_in(params, [:config, key], value)
  end
  defp add_parameter(params, "url", key, value) do
    put_in(params, [:config, "snapshots", key], value)
  end
  defp add_parameter(params, "auth", key, value) do
    params =
      if is_nil(params[:config]["auth"]) do
        put_in(params, [:config, "auth"], %{"basic" => %{}})
      else
        params
      end
    put_in(params, [:config, "auth", "basic", key], value)
  end

  defp add_url_parameter(params, nil, _type, _attr, _custom_value), do: params
  defp add_url_parameter(params, model, type, attr, custom_value) do
    params
    |> do_add_url_parameter(model.exid, type, VendorModel.get_url(model, attr), custom_value)
  end

  defp do_add_url_parameter(params, "other_default", _key, _value, nil), do: params
  defp do_add_url_parameter(params, _model, _key, nil, _custom_value), do: params
  defp do_add_url_parameter(params, "other_default", key, _value, custom_value) do
    put_in(params, [:config, "snapshots", key], custom_value)
  end
  defp do_add_url_parameter(params, _model, key, value, _custom_value) do
    put_in(params, [:config, "snapshots", key], value)
  end

  defp delete_camera_worker(camera) do
    MetaData.delete_by_camera_id(camera.id)
    CloudRecording.delete_by_camera_id(camera.id)
    CameraShare.delete_by_camera_id(camera.id)
    CameraShareRequest.delete_by_camera_id(camera.id)
    Archive.delete_by_camera(camera.id)
    Timelapse.delete_by_camera_id(camera.id)
    Camera.delete_by_id(camera.id)
  end

  defp delete_snapshot_worker(camera) do
    Camera.invalidate_camera(camera)
    Storage.delete_everything_for(camera.exid)
    CameraActivity.delete_by_camera_id(camera.id)
  end

  defp create_thumbnail(camera, mac_address) do
    args = %{
      camera_exid: camera.exid,
      url: Camera.snapshot_url(camera),
      username: Camera.username(camera),
      password: Camera.password(camera),
      vendor_exid: Camera.get_vendor_attr(camera, :exid),
      timestamp: Calendar.DateTime.Format.unix(Calendar.DateTime.now_utc)
    }
    timestamp = Calendar.DateTime.Format.unix(Calendar.DateTime.now_utc)
    response = CamClient.fetch_snapshot(args)

    case response do
      {:ok, data} ->
        Util.broadcast_snapshot(args[:camera_exid], data, timestamp)
        Storage.save(args[:camera_exid], args[:timestamp], data, args[:notes])
        Camera.update_status(camera, true, mac_address)
      {:error, error} ->
        Logger.error "[#{camera.exid}] [create_thumbnail] [error] [#{inspect error}]"
        Camera.update_status(camera, false, mac_address)
    end
  end

  defp send_email_notification(true, user, camera) do
    try do
      spawn fn ->
        WorkerSupervisor.start_worker(camera)
        mac_address = insert_mac_address(camera)
        create_thumbnail(camera, mac_address)
        EvercamMedia.UserMailer.camera_create_notification(user, camera)
      end
    catch _type, error ->
      Util.error_handler(error)
    end
  end
  defp send_email_notification(_mode, _user, _camera), do: :noop

  defp insert_mac_address(camera) do
    with {:ok, response} <- EvercamMedia.ONVIFClient.request(Camera.get_camera_info(camera.exid), "device_service", "GetNetworkInterfaces") do
      response |> Map.get("NetworkInterfaces") |> Map.get("Info") |> Map.get("HwAddress")
    else
      {:error, _, _} -> nil
    end
  end
end
