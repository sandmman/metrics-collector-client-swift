/**
* Copyright IBM Corporation 2016, 2017
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
* http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
**/

import Foundation
import Configuration
import CloudFoundryEnv
import LoggerAPI
import Yaml
import SwiftyRequest

public struct MetricsTrackerClient {
  let configMgr: ConfigurationManager
  let repository: String
  var organization: String?
  var codeVersion: String?

  public init(configMgr: ConfigurationManager, repository: String, organization: String? = "IBM", codeVersion: String? = nil) {
    self.repository = repository
    self.codeVersion = codeVersion
    self.configMgr = configMgr
    self.organization = organization
  }

  public init(repository: String, organization: String? = "IBM", codeVersion: String? = nil) {
    let configMgr = ConfigurationManager()
    configMgr.load(.environmentVariables)
    self.init(configMgr: configMgr, repository: repository, organization: organization, codeVersion: codeVersion)
  }

  /// Sends off HTTP post request to tracking service, simply logging errors on failure
  public func track() {
    Log.verbose("About to construct HTTP request for metrics-tracker-service...")

    guard let trackerJson = buildTrackerJson(configMgr: configMgr),
          let jsonData = try? JSONSerialization.data(withJSONObject: trackerJson) else {
      Log.verbose("Failed to build valid JSON payload for deployment tracker... maybe running locally and not on the cloud?")
      return
    }
    
    let jsonStr = String(data: jsonData, encoding: .utf8)
    Log.verbose("JSON payload for metrics-tracker-service is: \(String(describing: jsonStr))")
      
    // Build Request Instance

    let request = RestRequest(method: .post, url: "https://metrics-tracker.mybluemix.net:443/api/v1/track")
    request.contentType = "application/json; charset=utf-8"
    request.messageBody = jsonData
    
    request.responseData { response in
      switch response.result {
      case .success(let data):
        guard let jsonResponse = try? JSONSerialization.jsonObject(with: data, options: []) else {
          Log.error("Bad JSON payload received from metrics-tracker-service.")
          return
        }
  
        Log.info("metrics-tracker-service response: \(jsonResponse)")

      case .failure(let err):
          Log.error("Sending tracking data to metrics-tracker-service failed with error: \(err).")
      }
    }
    Log.verbose("Sent HTTP request to metrics-tracker-service...")
  }

  /// Helper method to build Json in a valid format for tracking service
  ///
  /// - parameter configMgr: application environment to pull Bluemix app data from
  ///
  /// - returns: JSON, assuming we have access to application info
  public func buildTrackerJson(configMgr: ConfigurationManager) -> [String:Any]? {
    var jsonEvent: [String:Any] = [:]
    let org = self.organization ?? "IBM"

    //Get the yaml file in the master's top level directory using the organization and repository name.
    let urlString = "https://raw.githubusercontent.com/" + org + "/" + repository + "/master/repository.yaml"
    let repoString = "https://github.com/" + org + "/" + repository
    var yaml = ""

    let semaphore = DispatchSemaphore(value: 0)

    RestRequest(url: urlString).responseData { response in
      switch response.result {
      case .success(let data):
          yaml = String(data: data, encoding: .utf8) ?? ""
      case .failure(let err):
        Log.error("Failed to retrieve yaml file with error: \(err)")
      }
      semaphore.signal()
    }

    semaphore.wait()
  
    Log.verbose("Preparing dictionary payload for metrics-tracker-service...")
    let dateFormatter = DateFormatter()
    #if os(OSX)
    //dateFormatter.calendar = Calendar(identifier: .iso8601)
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    #else
    //dateFormatter.calendar = Calendar(identifier: .iso8601)
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.timeZone = TimeZone(abbreviation: "GMT")
    #endif
    dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSX"
    jsonEvent["date_sent"] = dateFormatter.string(from: Date())

    if let codeVersion = self.codeVersion {
      jsonEvent["code_version"] = codeVersion
    }
    jsonEvent["runtime"] = "swift"
    jsonEvent["repository_url"] = repoString

    //If not deployed on Cloud Foundry, ignore all the CF environment variables.
    if let vcapApplication = configMgr.getApp() {

    jsonEvent["application_name"] = vcapApplication.name
    jsonEvent["space_id"] = vcapApplication.spaceId
    jsonEvent["application_id"] = vcapApplication.id
    jsonEvent["application_version"] = vcapApplication.version
    jsonEvent["application_uris"] = vcapApplication.uris
    jsonEvent["instance_index"] = vcapApplication.instanceIndex

    Log.verbose("Verifying services bound to application...")
    let services = configMgr.getServices()
    if services.count > 0 {
      var serviceDictionary = [String: Any]()
      var serviceDict = [String]()
      for (_, service) in services {
        do{
          serviceDict.append(service.name)
        }
        if var serviceStats = serviceDictionary[service.label] as? [String: Any] {
          if let count = serviceStats["count"] as? Int {
            serviceStats["count"] = count + 1
          }
          if var plans = serviceStats["plans"] as? [String] {
            if !plans.contains(service.plan) { plans.append(service.plan) }
            serviceStats["plans"] = plans
          }
          serviceDictionary[service.label] = serviceStats
        } else {
          var newService = [String: Any]()
          newService["count"] = 1
          newService["plans"] = service.plan.components(separatedBy: ", ")
          serviceDictionary[service.label] = newService
        }
      }
      jsonEvent["bound_vcap_services"] = serviceDictionary
      jsonEvent["bound_services"] = serviceDict
    }
  }

    //Convert the yaml string to Json.
    do {
    let journey_metric = try Yaml.load(yaml)
    var metrics = [String: Any]()
    if journey_metric["id"] != nil {
      metrics["repository_id"] = journey_metric["id"].string
    } else{
      metrics["repository_id"] = ""
    }
    if journey_metric["runtimes"] != nil {
      let target_runtimes = journey_metric["runtimes"].array
      var target_runtime: [String] = []
      for (runtime) in target_runtimes! {
        target_runtime.append(runtime.string!)
      }
      metrics["target_runtimes"] = target_runtime
    } else {
      metrics["target_runtimes"] = ""
    }
    if journey_metric["services"] != nil {
      let target_services = journey_metric["services"].array
      var target_service: [String] = []
      for (service) in target_services! {
        target_service.append(service.string!)
      }
      metrics["target_services"] = target_service
    } else {
      metrics["target_services"] = ""
    }
    if journey_metric["event_id"] != nil {
      metrics["event_id"] = journey_metric["event_id"].string
    } else {
      metrics["event_id"] = ""
    }
    if journey_metric["event_organizer"] != nil {
      metrics["event_organizer"] = journey_metric["event_organizer"].string
    } else {
      metrics["event_organizer"] = ""
    }
    if journey_metric["language"] != nil {
      jsonEvent["runtime"] = journey_metric["language"].string
    }
    jsonEvent["config"] = metrics
    } catch {
      Log.info("repository.yaml not exist.")
    }

    Log.verbose("Finished preparing dictionary payload for metrics-tracker-service.")
    Log.verbose("Dictionary payload for metrics-tracker-service is: \(jsonEvent)")
    return jsonEvent
  }
}
