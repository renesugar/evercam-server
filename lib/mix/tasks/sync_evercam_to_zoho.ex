defmodule EvercamMedia.SyncEvercamToZoho do
  alias EvercamMedia.Zoho
  require Logger

  def sync_cameras(email_or_username) do
    {:ok, _} = Application.ensure_all_started(:evercam_media)

    Logger.info "Start sync cameras to zoho."

    email_or_username
    |> User.by_username_or_email
    |> Camera.for(false)
    |> Zoho.insert_camera

    Logger.info "Camera(s) sync successfully."
  end
end
