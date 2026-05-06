require 'json'
require 'net/http'
require 'uri'
require 'base64'
require 'aws-sdk-bedrockruntime'
require 'slack-ruby-client'

def fetch_soracam_image
  auth_key_id = ENV.fetch('SORACAM_AUTH_KEY_ID')
  auth_key = ENV.fetch('SORACAM_AUTH_KEY')
  device_id = ENV.fetch('SORACAM_DEVICE_ID')

  credentials = get_soracom_credentials(auth_key_id, auth_key)
  export_id = get_soracam_export_id(credentials, device_id) # 必須：カメラON & Wi-Fiに接続済み & クラウド録画ON

  sleep(5) # エクスポートが完了するまで待機

  image = download_image(credentials, device_id, export_id)
end

def get_soracom_credentials(auth_key_id, auth_key)
  auth_uri = URI('https://api.soracom.io/v1/auth')
  auth_response = Net::HTTP.post(
    auth_uri,
    { authKeyId: auth_key_id, authKey: auth_key }.to_json,
    { 'Content-Type' => 'application/json' }
  )
  JSON.parse(auth_response.body)
end

def get_soracam_export_id(credentials, device_id)
  export_uri = URI("https://api.soracom.io/v1/sora_cam/devices/#{device_id}/images/exports")
  export_response = Net::HTTP.post(
    export_uri,
    { time: (Time.now.to_i * 1000) }.to_json,
    {
      'Content-Type' => 'application/json',
      'X-Soracom-API-Key' => credentials.fetch('apiKey'),
      'X-Soracom-Token' => credentials.fetch('token')
    }
  )
  JSON.parse(export_response.body).fetch('exportId')
end

def download_image(credentials, device_id, export_id)
  image_uri = URI("https://api.soracom.io/v1/sora_cam/devices/#{device_id}/images_exports/#{export_id}")
  image_response = Net::HTTP.get_response(
    image_uri,
    {
      'X-Soracom-API-Key' => credentials.fetch('apiKey'),
      'X-Soracom-Token' => credentials.fetch('token')
    }
  )
  image_url = JSON.parse(image_response.body).fetch('url')
  URI.open(image_url).read
end

def analyze_image(image)
  client = Aws::BedrockRuntime::Client.new(region: 'ap-northeast-1')

  response = client.invoke_model(
    model_id: 'anthropic.claude-3-5-sonnet-20241022-v2:0',
    content_type: 'application/json',
    body: {
      anthropic_version: 'bedrock-2023-05-31',
      max_tokens: 256,
      messages: [
        {
          role: 'user',
          content: [
            {
              type: 'image',
              source: {
                type: 'base64',
                media_type: 'image/jpeg',
                data: Base64.strict_encode64(image)
              }
            },
            {
              type: 'text',
              text: '猫のフードボウルに餌が入っていますか？「true」か「false」だけで答えてください。'
            }
          ]
        }
      ]
    }.to_json
  )

  result = JSON.parse(response.body.read)
  result.dig('content', 0, 'text').strip.downcase == 'true'
end

def notify_slack(result)
  token = ENV.fetch('SLACK_BOT_TOKEN')
  channel = ENV.fetch('SLACK_CHANNEL_ID')
  text = result ? 'ごはんが入っています。' : 'ごはんが入っていません。'

  Slack::Web::Client.new(token:).chat_postMessage(
    channel:,
    text:
  )
end

def handler(event:, context:)
  image = fetch_soracam_image
  result = analyze_image(image)
  notify_slack(result)
  {statusCode: 200, body: "OK"}
end
