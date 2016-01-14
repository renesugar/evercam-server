defmodule EvercamMedia.Snapshot.DBHandler do
  @moduledoc """
  This module should ideally delegate all the updates to be made to the database
  on various events to another module.

  Right now, this is a extracted and slightly modified from the previous version of
  worker.

  These are the list of tasks for the db handler
    * Create an entry in the snapshots table for each retrived snapshots
    * Update the CameraActivity table whenever there is a change in the camera status
    * Update the status and last_polled_at values of Camera table
    * Update the thumbnail_url of the Camera table - This was done in the previous
    version and not now. This update can be avoided if thumbnails can be dynamically
    served.
  """
  use GenEvent
  require Logger
  alias EvercamMedia.Repo
  alias EvercamMedia.SnapshotRepo
  alias EvercamMedia.Util


  def handle_event({:got_snapshot, data}, state) do
    {camera_exid, timestamp, image} = data
    notes = "Evercam Proxy"
    Logger.debug "[#{camera_exid}] [snapshot_success]"

    case previous_image = ConCache.get(:cache, camera_exid) do
      %{} ->
        Logger.debug "Going to calculate MD"
        motion_level = EvercamMedia.MotionDetection.Lib.compare(image,previous_image[:image])
        Logger.debug "calculated motion level is #{motion_level}"
      _ ->
        Logger.debug "No previous image found in the cache"
        motion_level = nil
    end

    spawn fn ->
      try do
        update_camera_status("#{camera_exid}", timestamp, true, true)
        |> save_snapshot_record(timestamp, motion_level, notes)
      rescue
        error ->
          Util.error_handler(error)
      end
    end
    ConCache.put(:cache, camera_exid, %{image: image, timestamp: timestamp, notes: notes})
    {:ok, state}
  end

  def handle_event({:snapshot_error, data}, state) do
    {camera_exid, timestamp, error} = data
    parse_snapshot_error(camera_exid, timestamp, error)
    {:ok, state}
  end

  def handle_event(_, state) do
    {:ok, state}
  end

  def parse_snapshot_error(camera_exid, timestamp, error) do
    case error do
      %CaseClauseError{} ->
        reason = :bad_request
      %HTTPotion.HTTPError{} ->
        reason = Map.get(error, :message) |> String.to_atom
      error when is_map(error) ->
        reason = Map.get(error, :reason)
      _ ->
        reason = error
    end
    handle_snapshot_error(camera_exid, timestamp, error, reason)
  end

  def handle_snapshot_error(camera_exid, timestamp, error, reason) do
    case reason do
      :system_limit ->
        Logger.error "[#{camera_exid}] [snapshot_error] [system_limit] Traceback."
        Util.error_handler(error)
        [500, %{message: "Sorry, we dropped the ball."}]
      :bad_request ->
        Logger.error "[#{camera_exid}] [snapshot_error] [bad_request] Traceback."
        Logger.error inspect(error)
        update_camera_status("#{camera_exid}", timestamp, false)
        [504, %{message: "Bad request."}]
      :closed ->
        Logger.error "[#{camera_exid}] [snapshot_error] [closed] Traceback."
        Logger.error inspect(error)
        [504, %{message: "Connection closed."}]
      :emfile ->
        Logger.error "[#{camera_exid}] [snapshot_error] [emfile] Traceback."
        Util.error_handler(error)
        [500, %{message: "Sorry, we dropped the ball."}]
      :nxdomain ->
        Logger.info "[#{camera_exid}] [snapshot_error] [nxdomain]"
        update_camera_status("#{camera_exid}", timestamp, false)
        [504, %{message: "Non-existant domain."}]
      :ehostunreach ->
        Logger.info "[#{camera_exid}] [snapshot_error] [ehostunreach]"
        update_camera_status("#{camera_exid}", timestamp, false)
        [504, %{message: "No route to host."}]
      :enetunreach ->
        Logger.info "[#{camera_exid}] [snapshot_error] [enetunreach]"
        update_camera_status("#{camera_exid}", timestamp, false)
        [504, %{message: "Network unreachable."}]
      :timeout ->
        Logger.info "[#{camera_exid}] [snapshot_error] [timeout]"
        [504, %{message: "Camera response timed out."}]
      :connect_timeout ->
        Logger.debug "[#{camera_exid}] [snapshot_error] [connect_timeout]"
        update_camera_status("#{camera_exid}", timestamp, false)
        [504, %{message: "Connection to the camera timed out."}]
      :econnrefused ->
        Logger.info "[#{camera_exid}] [snapshot_error] [econnrefused]"
        update_camera_status("#{camera_exid}", timestamp, false)
        [504, %{message: "Connection refused."}]
      :not_found ->
        Logger.info "[#{camera_exid}] [snapshot_error] [not_found]"
        update_camera_status("#{camera_exid}", timestamp, false)
        [504, %{message: "Camera url is not found.", response: error[:response]}]
      :forbidden ->
        Logger.info "[#{camera_exid}] [snapshot_error] [forbidden]"
        update_camera_status("#{camera_exid}", timestamp, false)
        [504, %{message: "Camera responded with a Forbidden message.", response: error[:response]}]
      :unauthorized ->
        Logger.info "[#{camera_exid}] [snapshot_error] [unauthorized]"
        update_camera_status("#{camera_exid}", timestamp, false)
        [504, %{message: "Camera responded with a Unauthorized message.", response: error[:response]}]
      :device_error ->
        Logger.info "[#{camera_exid}] [snapshot_error] [device_error]"
        update_camera_status("#{camera_exid}", timestamp, false)
        [504, %{message: "Camera responded with a Device Error message.", response: error[:response]}]
      :device_busy ->
        Logger.info "[#{camera_exid}] [snapshot_error] [device_busy]"
        [502, %{message: "Camera responded with a Device Busy message.", response: error[:response]}]
      :not_a_jpeg ->
        Logger.info "[#{camera_exid}] [snapshot_error] [not_a_jpeg]"
        [504, %{message: "Camera didn't respond with an image.", response: error[:response]}]
      _reason ->
        Logger.info "[#{camera_exid}] [snapshot_error] [unhandled] #{inspect error}"
        [500, %{message: "Sorry, we dropped the ball."}]
    end
  end

  def update_camera_status(camera_exid, timestamp, status, update_thumbnail? \\ false) do
    camera_is_online = ConCache.get(:camera_status, camera_exid)

    if camera_is_online != status do
      {:ok, datetime} =
        Calendar.DateTime.Parse.unix!(timestamp)
        |> Calendar.DateTime.to_erl
        |> Ecto.DateTime.cast
      camera = Repo.one! Camera.by_exid(camera_exid)
      camera = construct_camera(camera, datetime, status, camera_is_online == status)
      Repo.update camera
      ConCache.put(:camera_status, camera_exid, status)
      log_camera_status(camera.id, status, datetime)
      invalidate_camera_cache(camera_exid)
    end

    camera_exid
  end

  def invalidate_camera_cache(camera_exid) do
    Exq.Enqueuer.enqueue(
      :exq_enqueuer,
      "cache",
      "Evercam::CacheInvalidationWorker",
      camera_exid
    )
  end

  def log_camera_status(camera_id, true, datetime) do
    SnapshotRepo.insert %CameraActivity{camera_id: camera_id, action: "online", done_at: datetime}
    camera = Repo.one! Camera.by_id_with_owner(camera_id)
    if camera.is_online_email_owner_notification do
      EvercamMedia.UserMailer.camera_online(camera.owner, camera)
    end
  end

  def log_camera_status(camera_id, false, datetime) do
    SnapshotRepo.insert %CameraActivity{camera_id: camera_id, action: "offline", done_at: datetime}
    camera = Repo.one! Camera.by_id_with_owner(camera_id)
    if camera.is_online_email_owner_notification do
      EvercamMedia.UserMailer.camera_offline(camera.owner, camera)
    end
  end

  def save_snapshot_record(camera_exid, timestamp, motion_level, notes) do
    {:ok, datetime} =
      Calendar.DateTime.Parse.unix!(timestamp)
      |> Calendar.DateTime.to_erl
      |> Ecto.DateTime.cast
    {:ok, snapshot_timestamp} =
      Calendar.DateTime.Parse.unix!(timestamp)
      |> Calendar.Strftime.strftime "%Y%m%d%H%M%S%f"

    camera_id = ConCache.get(:camera_status, "#{camera_exid}_id")
    snapshot_id = Util.format_snapshot_id(camera_id, snapshot_timestamp)
    SnapshotRepo.insert(%Snapshot{camera_id: camera_id, notes: notes, motionlevel: motion_level, created_at: datetime, snapshot_id: snapshot_id})
  end

  defp construct_camera(camera, datetime, _, true) do
    %{camera | last_polled_at: datetime}
  end

  defp construct_camera(camera, datetime, false, false) do
    %{camera | last_polled_at: datetime, is_online: false}
  end

  defp construct_camera(camera, datetime, true, false) do
    %{camera | last_polled_at: datetime, is_online: true, last_online_at: datetime}
  end
end
