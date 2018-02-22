defmodule EvercamMediaWeb.NVRController do
  use EvercamMediaWeb, :controller
  alias EvercamMediaWeb.SnapshotExtractorView
  alias EvercamMediaWeb.ErrorView
  alias EvercamMedia.HikvisionNVR
  alias EvercamMedia.Repo

  @root_dir Application.get_env(:evercam_media, :storage_dir)

  def get_info(conn, %{"id" => exid}) do
    current_user = conn.assigns[:current_user]
    camera = Camera.by_exid_with_associations(exid)

    with :ok <- ensure_camera_exists(camera, exid, conn),
         :ok <- ensure_can_edit(current_user, camera, conn)
    do
      ip = Camera.host(camera, "external")
      port = Camera.get_nvr_port(camera)
      cam_username = Camera.username(camera)
      cam_password = Camera.password(camera)
      channel = VendorModel.get_channel(camera, camera.vendor_model.channel)

      stream_info = HikvisionNVR.get_stream_info(ip, port, cam_username, cam_password, channel)
      device_info = HikvisionNVR.get_device_info(ip, port, cam_username, cam_password)
      hdd_info = HikvisionNVR.get_hdd_info(ip, port, cam_username, cam_password)
      json(conn, %{stream_info: stream_info, device_info: device_info, hdd_info: hdd_info})
    end
  end

  def get_vh_info(conn, %{"id" => exid}) do
    current_user = conn.assigns[:current_user]
    camera = Camera.by_exid_with_associations(exid)

    with :ok <- ensure_camera_exists(camera, exid, conn),
         :ok <- ensure_can_edit(current_user, camera, conn)
    do
      ip = Camera.host(camera, "external")
      port = Camera.get_nvr_port(camera)
      cam_username = Camera.username(camera)
      cam_password = Camera.password(camera)
      channel = VendorModel.get_channel(camera, camera.vendor_model.channel)

      vh_info = HikvisionNVR.get_vh_info(ip, port, cam_username, cam_password, channel)

      response =
        case Map.get(vh_info, :vh_port) do
          nil -> %{vh_info: vh_info, vh_stream_info: %{}, vh_device_info: %{}}
          "" -> %{vh_info: vh_info, vh_stream_info: %{}, vh_device_info: %{}}
          vh_port ->
            vh_stream_info = HikvisionNVR.get_stream_info(ip, vh_port, cam_username, cam_password, channel)
            vh_device_info = HikvisionNVR.get_device_info(ip, vh_port, cam_username, cam_password)
            %{vh_info: vh_info, vh_stream_info: vh_stream_info, vh_device_info: vh_device_info}
        end

      json(conn, response)
    end
  end

  def extract_snapshots(conn, %{"id" => exid, "start_date" => start_date, "end_date" => end_date, "interval" => interval} = params) do
    current_user = conn.assigns[:current_user]
    camera = Camera.by_exid_with_associations(exid)

    with :ok <- ensure_camera_exists(camera, exid, conn),
         :ok <- ensure_can_edit(current_user, camera, conn),
         :ok <- ensure_process_exists(camera, conn)
    do
      host = Camera.host(camera, "external")
      port = Camera.port(camera, "external", "rtsp")
      cam_username = Camera.username(camera)
      cam_password = Camera.password(camera)
      url = camera.vendor_model.h264_url
      channel = url |> String.split("/channels/") |> List.last |> String.split("/") |> List.first
      config =
        %{
          exid: camera.exid,
          timezone: Camera.get_timezone(camera),
          host: host,
          port: port,
          username: cam_username,
          password: cam_password,
          channel: channel,
          start_date: convert_timestamp(start_date),
          end_date: convert_timestamp(end_date),
          interval: String.to_integer(interval),
          schedule: get_schedule(params["schedule"])
        }

      config
      |> snapshot_extractor_changeset(camera.id, params["requester"], current_user)
      |> Repo.insert
      |> case do
        {:ok, snapshot_extractor} ->
          full_snapshot_extractor = Repo.preload(snapshot_extractor, :camera, force: true)
          spawn(fn ->
            EvercamMedia.UserMailer.snapshot_extraction_started(full_snapshot_extractor)
            start_snapshot_extractor(config, full_snapshot_extractor.id)
          end)
          conn
          |> put_status(:created)
          |> render(SnapshotExtractorView, "show.json", %{snapshot_extractor: full_snapshot_extractor})
        {:error, changeset} ->
          render_error(conn, 400, Util.parse_changeset(changeset))
      end
    end
  end

  defp snapshot_extractor_changeset(config, id, requester, user) do
    params =
      %{
        camera_id: id,
        from_date: config.start_date,
        to_date: config.end_date,
        interval: config.interval,
        schedule: config.schedule,
        status: 11,
        requestor: get_requester(requester, user)
      }
    SnapshotExtractor.changeset(%SnapshotExtractor{}, params)
  end

  defp start_snapshot_extractor(config, id) do
    config = Map.put(config, :id, id)
    case Process.whereis(:snapshot_extractor) do
      nil ->
        {:ok, pid} = GenStage.start_link(EvercamMedia.SnapshotExtractor.Extractor, {}, name: :snapshot_extractor)
        pid
      pid -> pid
    end
    |> GenStage.cast({:snapshot_extractor, config})
  end

  defp get_requester(value, user) when value in [nil, ""], do: user.email
  defp get_requester(value, _user), do: value

  defp ensure_camera_exists(nil, exid, conn) do
    conn
    |> put_status(404)
    |> render(ErrorView, "error.json", %{message: "Camera '#{exid}' not found!"})
  end
  defp ensure_camera_exists(_camera, _id, _conn), do: :ok

  defp ensure_can_edit(current_user, camera, conn) do
    if Permission.Camera.can_edit?(current_user, camera) do
      :ok
    else
      conn
      |> put_status(403)
      |> render(ErrorView, "error.json", %{message: "You don't have sufficient rights for this."})
    end
  end

  defp convert_timestamp(timestamp) do
    timestamp
    |> String.to_integer
    |> Calendar.DateTime.Parse.unix!
  end

  defp ensure_process_exists(camera, conn) do
    case Porcelain.shell("ps -ef | grep ffmpeg | grep '#{@root_dir}/#{camera.exid}/extract/' | grep -v grep | awk '{print $2}'").out do
      "" -> :ok
      _ ->
        conn
        |> put_status(400)
        |> render(ErrorView, "error.json", %{message: "Snapshot extractor already processing for this camera '#{camera.name}'."})
    end
  end

  defp get_schedule(schedule) when schedule in [nil, ""] do
    Poison.decode!("{\"Wednesday\":[\"08:00-18:00\"],\"Tuesday\":[\"00:00-18:00\"],\"Thursday\":[\"00:00-18:00\"],\"Sunday\":[\"00:00-18:00\"],\"Saturday\":[\"00:00-18:00\"],\"Monday\":[\"00:00-18:00\"],\"Friday\":[\"00:00-08:00\"]}")
  end
  defp get_schedule(schedule), do: Poison.decode!(schedule)
end
